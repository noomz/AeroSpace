import AppKit
import Common

/// First line of defence against lock screen
///
/// When you lock the screen, all accessibility API becomes unobservable (all attributes become empty, window id
/// becomes nil, etc.) which tricks AeroSpace into thinking that all windows were closed.
/// That's why every time a window dies AeroSpace caches the "entire world" (unless window is already presented in the cache)
/// so that once the screen is unlocked, AeroSpace could restore windows to where they were
@MainActor private var closedWindowsCache = FrozenWorld(monitors: [], windowIds: [])

/// Whether the screen is locked right now. See: onScreenLocked, onScreenUnlocked
@MainActor private var isScreenLocked = false
/// Read-only view for the window-events diff, which freezes while the screen is locked
@MainActor var screenIsLocked: Bool { isScreenLocked }
/// Whether the screen was locked at any point since closedWindowsCache was captured.
///
/// The cache exists only to survive the lock screen. macOS reuses window IDs of closed windows for brand new windows,
/// so if the cache was never "tested" by a lock screen, a matching window ID means a new window that got a recycled ID,
/// not a window that came back from the lock screen. Restoring the cache in that case moves the new window (and
/// everything else in the cache) to wherever the dead window used to be. https://github.com/nikitabobko/AeroSpace/issues/2234
@MainActor private var screenWasLockedSinceCaching = false

struct FrozenMonitor: Sendable {
    let visibleWorkspace: String
    let topLeftCorner: CGPoint
    let workspaces: [FrozenWorkspace]

    @MainActor init(_ monitor: Monitor) {
        self.topLeftCorner = monitor.info.rect.topLeftCorner
        self.workspaces = monitor.getWorkspacesContainerOrCreate().children.map { FrozenWorkspace($0 as! Workspace) }
        self.visibleWorkspace = monitor.getWorkspacesContainerOrCreate().getVisibleWorkspaceOrCreate(parent: monitor).name
    }
}

struct FrozenWorkspace: Sendable {
    let name: String
    let rootTilingNode: FrozenContainer
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [FrozenWindow]

    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        rootTilingNode = FrozenContainer(workspace.rootTilingContainer)
        floatingWindows = workspace.floatingWindows.map(FrozenWindow.init)
        macosUnconventionalWindows =
            workspace.macOsNativeHiddenAppsWindowsContainer.children.map { FrozenWindow($0 as! Window) } +
            workspace.macOsNativeFullscreenWindowsContainer.children.map { FrozenWindow($0 as! Window) }
    }
}

@MainActor func cacheClosedWindowIfNeeded() {
    let allWs = Workspace.all
    let allWindowIds = allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
    if allWindowIds.isSubset(of: closedWindowsCache.windowIds) {
        return // already cached
    }
    closedWindowsCache = FrozenWorld(
        monitors: Monitor.all.map(FrozenMonitor.init),
        windowIds: allWindowIds,
    )
    // If the screen is locked, the window died because of the lock screen (or at least it's indistinguishable from it)
    screenWasLockedSinceCaching = isScreenLocked
}

@MainActor func onScreenLocked() {
    isScreenLocked = true
    screenWasLockedSinceCaching = true
}

@MainActor func onScreenUnlocked() {
    isScreenLocked = false
}

@MainActor func restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    if !screenWasLockedSinceCaching || !closedWindowsCache.windowIds.contains(newlyDetectedWindow.windowId) {
        return false
    }
    let monitors = globalUnsortedMonitorInfos
    let topLeftCornerToMonitorInfo = monitors.grouped { $0.rect.topLeftCorner }
    // Resolve the windows before the restore detaches any tree
    let windows: [OpaqueWindowId: Window] = closedWindowsCache.windowIds.reduce(into: [:]) { $0[$1] = MacWindow.get(byId: $1) }

    for monitor in closedWindowsCache.monitors {
        for frozenWorkspace in monitor.workspaces {
            let workspace = Workspace.get(byName: frozenWorkspace.name)
            _ = topLeftCornerToMonitorInfo[monitor.topLeftCorner]?
                .singleOrNil()?
                .bindWorkspace(workspace)
            for frozenWindow in frozenWorkspace.floatingWindows {
                windows[frozenWindow.id]?.bindAsFloatingWindow(to: workspace)
            }
            for frozenWindow in frozenWorkspace.macosUnconventionalWindows { // Will get fixed by normalizations
                windows[frozenWindow.id]?.bindAsFloatingWindow(to: workspace)
            }
            let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
            let potentialOrphans = prevRoot.allLeafWindowsRecursive
            prevRoot.unbindFromParent()
            restoreTreeRecursive(frozenWorkspace.rootTilingNode, parent: workspace, index: INDEX_BIND_LAST, windows)
            for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
                try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
            }
        }

        _ = topLeftCornerToMonitorInfo[monitor.topLeftCorner]?
            .singleOrNil()?
            .setVisibleWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
    return true
}

/// Windows that haven't re-registered yet are skipped. Present children are bound to the end in frozen order, because a
/// skipped sibling would make the frozen index point past the real children. Every re-registered window reruns the
/// restore, so the order becomes exact once all windows are back. Empty containers are removed by normalizeContainers
@MainActor
private func restoreTreeRecursive(
    _ frozenContainer: FrozenContainer,
    parent: NonLeafTreeNodeObject,
    index: Int,
    _ windows: [OpaqueWindowId: Window],
) {
    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: frozenContainer.weight,
        frozenContainer.orientation,
        frozenContainer.layout,
        index: index,
    )

    for child in frozenContainer.children {
        switch child {
            case .window(let w):
                windows[w.id]?.bind(to: container, adaptiveWeight: w.weight, index: INDEX_BIND_LAST)
            case .container(let c):
                restoreTreeRecursive(c, parent: container, index: INDEX_BIND_LAST, windows)
        }
    }
}

// Consider the following case:
// 1. Close window
// 2. The previous step lead to caching the whole world
// 3. Change something in the layout
// 4. Lock the screen
// 5. The cache won't be updated because all alive windows are already cached
// 6. Unlock the screen
// 7. The wrong cache is used
//
// That's why we have to reset the cache every time layout changes. The layout can only be changed by running commands
// and with mouse manipulations
@MainActor func resetClosedWindowsCache() {
    closedWindowsCache = FrozenWorld(monitors: [], windowIds: [])
    screenWasLockedSinceCaching = false
}
