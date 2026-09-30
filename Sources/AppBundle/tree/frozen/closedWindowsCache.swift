import AppKit
import Common

/// First line of defence against lock screen
///
/// When you lock the screen, all accessibility API becomes unobservable (all attributes become empty, window id
/// becomes nil, etc.) which tricks AeroSpace into thinking that all windows were closed.
/// That's why every time a window dies AeroSpace caches the "entire world" (unless window is already presented in the cache)
/// so that once the screen is unlocked, AeroSpace could restore windows to where they were
@MainActor private var closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])

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
    let topLeftCorner: CGPoint
    let visibleWorkspace: String

    @MainActor init(_ monitor: MonitorInfo) {
        topLeftCorner = monitor.rect.topLeftCorner
        visibleWorkspace = monitor.activeWorkspace.name
    }
}

struct FrozenWorkspace: Sendable {
    let name: String
    let monitor: FrozenMonitor // todo drop this property, once monitor to workspace assignment migrates to TreeNode
    let rootTilingNode: FrozenContainer
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [FrozenWindow]

    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        monitor = FrozenMonitor(workspace.workspaceMonitor)
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
        workspaces: allWs.map { FrozenWorkspace($0) },
        monitors: monitorInfos.map(FrozenMonitor.init),
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
    let monitors = monitorInfos
    let topLeftCornerToMonitor = monitors.grouped { $0.rect.topLeftCorner }

    for frozenWorkspace in closedWindowsCache.workspaces {
        let workspace = Workspace.get(byName: frozenWorkspace.name)
        _ = topLeftCornerToMonitor[frozenWorkspace.monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(workspace)
        for frozenWindow in frozenWorkspace.floatingWindows {
            MacWindow.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        for frozenWindow in frozenWorkspace.macosUnconventionalWindows { // Will get fixed by normalizations
            MacWindow.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
        let potentialOrphans = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()
        restoreTreeRecursive(frozenContainer: frozenWorkspace.rootTilingNode, parent: workspace, index: INDEX_BIND_LAST)
        for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
            try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
        }
    }

    for monitor in closedWindowsCache.monitors {
        _ = topLeftCornerToMonitor[monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
    return true
}

@discardableResult
@MainActor
private func restoreTreeRecursive(frozenContainer: FrozenContainer, parent: NonLeafTreeNodeObject, index: Int) -> Bool {
    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: frozenContainer.weight,
        frozenContainer.orientation,
        frozenContainer.layout,
        index: index,
    )

    for (index, child) in frozenContainer.children.enumerated() {
        switch child {
            case .window(let w):
                // Stop the loop if can't find the window, because otherwise all the subsequent windows will have incorrect index
                guard let window = MacWindow.get(byId: w.id) else { return false }
                window.bind(to: container, adaptiveWeight: w.weight, index: index)
            case .container(let c):
                // There is no reason to continue
                if !restoreTreeRecursive(frozenContainer: c, parent: container, index: index) { return false }
        }
    }
    return true
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
    closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])
    screenWasLockedSinceCaching = false
}
