import Common

/// What `window-moved`/`window-closed` need to know about a window, diffed at the end of refresh sessions.
struct WindowSnapshotEntry: Equatable {
    let workspace: String
    let appBundleId: String?
    let appName: String?
}

typealias WindowSnapshot = [UInt32: WindowSnapshotEntry]

/// Diffs two window snapshots into `window-moved` and `window-closed` events and returns the snapshot to keep.
///
/// - Window absent from `old` -> `window-moved` without `prevWorkspace` (first appearance). The diff runs after
///   `on-window-detected` callbacks, so subscribers see where the callbacks left the window.
/// - Workspace changed -> `window-moved` with `prevWorkspace`. Rebinds within a workspace are invisible.
/// - Window absent from `new` -> `window-closed`. A recycled window id (same id, other app) is a close plus a first
///   appearance.
/// - `sticky` windows are rebound to the visible workspace all the time: they never emit `window-moved` (their entry
///   updates silently), while `window-closed` still fires.
/// - `isLocked`: the lock screen makes every window look closed; the pre-lock snapshot is kept, and nothing is emitted,
///   so after unlock only real changes show up.
/// - `isFirstDiff`: windows present when AeroSpace starts are not arrivals; the snapshot is seeded silently.
func diffWindowSnapshots(
    old: WindowSnapshot,
    new: WindowSnapshot,
    isLocked: Bool,
    sticky: Set<UInt32>,
    isFirstDiff: Bool,
) -> (events: [ServerEvent], snapshot: WindowSnapshot) {
    if isFirstDiff { return ([], new) }
    if isLocked { return ([], old) }
    var closed: [ServerEvent] = []
    var moved: [ServerEvent] = []
    for (id, was) in old.sorted(by: { $0.key < $1.key }) {
        if let now = new[id], now.appBundleId == was.appBundleId { continue }
        closed.append(.windowClosed(windowId: id, workspace: was.workspace, appBundleId: was.appBundleId))
    }
    for (id, now) in new.sorted(by: { $0.key < $1.key }) where !sticky.contains(id) {
        let was = old[id].flatMap { $0.appBundleId == now.appBundleId ? $0 : nil }
        if was?.workspace == now.workspace { continue }
        moved.append(.windowMoved(
            windowId: id,
            workspace: now.workspace,
            prevWorkspace: was?.workspace,
            appBundleId: now.appBundleId,
            appName: now.appName,
        ))
    }
    return (closed + moved, new)
}

/// Whether the diff is frozen for this check, and whether it stays frozen for the next one.
///
/// Behind the lock screen AeroSpace garbage-collects every window and re-registers them only in the first heavy
/// refresh session after unlock. So the diff freezes at lock and thaws only at the end of that session: a light
/// session in between (any CLI call) would otherwise see every window closed, then every window appear again.
func windowDiffFreeze(isLocked: Bool, unlockPending: Bool, endOfHeavySession: Bool) -> (frozen: Bool, unlockPending: Bool) {
    if isLocked { return (true, true) }
    if unlockPending && !endOfHeavySession { return (true, true) }
    return (false, false)
}

@MainActor private var windowSnapshot: WindowSnapshot? = nil
@MainActor private var unlockPending = false

/// Broadcasts `window-moved`/`window-closed` for what changed since the last check. Runs at the end of
/// `refreshModel_nonCancellable` and of a heavy refresh session, after `on-window-detected` callbacks and
/// `normalizeLayoutReason`.
///
/// The first snapshot is taken only at the end of a heavy session: at startup `refreshModel_nonCancellable` runs before
/// any window is registered, and seeding there would announce every existing window as an arrival.
@MainActor func checkWindowEvents(endOfHeavySession: Bool) {
    let freeze = windowDiffFreeze(isLocked: screenIsLocked, unlockPending: unlockPending, endOfHeavySession: endOfHeavySession)
    unlockPending = freeze.unlockPending
    if windowSnapshot == nil && (!endOfHeavySession || freeze.frozen) { return }
    var new: WindowSnapshot = [:]
    var sticky: Set<UInt32> = []
    for window in MacWindow.allWindows {
        if window.isSticky { sticky.insert(window.windowId) }
        if let workspace = window.nodeWorkspace?.name {
            new[window.windowId] = WindowSnapshotEntry(
                workspace: workspace,
                appBundleId: window.app.rawAppBundleId,
                appName: window.app.name,
            )
        } else if let was = windowSnapshot?[window.windowId] {
            new[window.windowId] = was // alive, outside any workspace for now: neither a move nor a close
        }
    }
    let (events, snapshot) = diffWindowSnapshots(
        old: windowSnapshot ?? [:],
        new: new,
        isLocked: freeze.frozen,
        sticky: sticky,
        isFirstDiff: windowSnapshot == nil,
    )
    windowSnapshot = snapshot
    for event in events {
        broadcastEvent(event)
    }
}
