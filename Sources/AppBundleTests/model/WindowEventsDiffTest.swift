@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WindowEventsDiffTest {
    private let kitty = WindowSnapshotEntry(workspace: "T", appBundleId: "net.kovidgoyal.kitty", appName: "kitty")

    private func diff(
        _ old: WindowSnapshot,
        _ new: WindowSnapshot,
        isLocked: Bool = false,
        sticky: Set<OpaqueWindowId> = [],
        isFirstDiff: Bool = false,
    ) -> (events: [ServerEvent], snapshot: WindowSnapshot) {
        diffWindowSnapshots(old: old, new: new, isLocked: isLocked, sticky: sticky, isFirstDiff: isFirstDiff)
    }

    private func on(_ workspace: String, _ e: WindowSnapshotEntry) -> WindowSnapshotEntry {
        WindowSnapshotEntry(workspace: workspace, appBundleId: e.appBundleId, appName: e.appName)
    }

    @Test func testFirstAppearanceHasNoPrevWorkspace() {
        let r = diff([:], [1: kitty])
        assertEquals(r.events, [
            .windowMoved(windowId: 1, workspace: "T", prevWorkspace: nil, appBundleId: "net.kovidgoyal.kitty", appName: "kitty"),
        ])
        assertEquals(r.snapshot, [1: kitty])
    }

    @Test func testMoveCarriesPrevWorkspace() {
        let r = diff([1: on("1", kitty)], [1: kitty])
        assertEquals(r.events, [
            .windowMoved(windowId: 1, workspace: "T", prevWorkspace: "1", appBundleId: "net.kovidgoyal.kitty", appName: "kitty"),
        ])
    }

    @Test func testCloseCarriesTheLastWorkspace() {
        let r = diff([1: kitty], [:])
        assertEquals(r.events, [.windowClosed(windowId: 1, workspace: "T", appBundleId: "net.kovidgoyal.kitty")])
        assertEquals(r.snapshot, [:])
    }

    @Test func testWithinWorkspaceRebindIsSilent() {
        // Same workspace in both snapshots, whatever happened to the tree in between
        let r = diff([1: kitty, 2: on("1", kitty)], [1: kitty, 2: on("1", kitty)])
        assertEquals(r.events, [])
    }

    @Test func testLockFreezesTheSnapshotSoUnlockEmitsNoBurst() {
        let before: WindowSnapshot = [1: kitty, 2: on("1", kitty)]
        let locked = diff(before, [:], isLocked: true) // every window looks closed behind the lock screen
        assertEquals(locked.events, [])
        assertEquals(locked.snapshot, before)
        let unlocked = diff(locked.snapshot, before) // cache restored every window where it was
        assertEquals(unlocked.events, [])
    }

    @Test func testFreezeLastsFromLockUntilTheFirstHeavySessionAfterUnlock() {
        let locked = windowDiffFreeze(isLocked: true, unlockPending: false, endOfHeavySession: false)
        assertEquals(locked.frozen, true)
        let light = windowDiffFreeze(isLocked: false, unlockPending: locked.unlockPending, endOfHeavySession: false)
        assertEquals(light.frozen, true) // unlocked, windows not re-registered yet
        let heavy = windowDiffFreeze(isLocked: false, unlockPending: light.unlockPending, endOfHeavySession: true)
        assertEquals(heavy.frozen, false)
        assertEquals(heavy.unlockPending, false)
        let normal = windowDiffFreeze(isLocked: false, unlockPending: false, endOfHeavySession: false)
        assertEquals(normal.frozen, false)
    }

    @Test func testNoBurstWhileWindowsAreStillGoneAfterUnlock() {
        let before: WindowSnapshot = [1: kitty, 2: on("1", kitty)]
        var pending = false
        var snapshot = before
        // lock (every window garbage-collected), unlock, a light session, then the heavy session restoring them
        for (isLocked, heavy, world) in [(true, false, [:]), (false, false, [:]), (false, true, before)] as [(Bool, Bool, WindowSnapshot)] {
            let freeze = windowDiffFreeze(isLocked: isLocked, unlockPending: pending, endOfHeavySession: heavy)
            pending = freeze.unlockPending
            let r = diff(snapshot, world, isLocked: freeze.frozen)
            assertEquals(r.events, [])
            snapshot = r.snapshot
        }
        assertEquals(snapshot, before)
    }

    @Test func testStickyNeverMovesButStillCloses() {
        let bitwarden = WindowSnapshotEntry(workspace: "1", appBundleId: "com.bitwarden.desktop", appName: "Bitwarden")
        let moved = diff([7: bitwarden], [7: on("2", bitwarden)], sticky: [7])
        assertEquals(moved.events, [])
        assertEquals(moved.snapshot, [7: on("2", bitwarden)]) // the entry updates silently
        assertEquals(diff([:], [7: bitwarden], sticky: [7]).events, [])
        assertEquals(diff([7: bitwarden], [:], sticky: []).events, [
            .windowClosed(windowId: 7, workspace: "1", appBundleId: "com.bitwarden.desktop"),
        ])
    }

    @Test func testStartupSeedsSilently() {
        let r = diff([:], [1: kitty, 2: on("1", kitty)], isFirstDiff: true)
        assertEquals(r.events, [])
        assertEquals(r.snapshot, [1: kitty, 2: on("1", kitty)])
    }

    @Test func testRecycledWindowIdIsACloseAndAFirstAppearance() {
        let safari = WindowSnapshotEntry(workspace: "T", appBundleId: "com.apple.Safari", appName: "Safari")
        let r = diff([1: kitty], [1: safari])
        assertEquals(r.events, [
            .windowClosed(windowId: 1, workspace: "T", appBundleId: "net.kovidgoyal.kitty"),
            .windowMoved(windowId: 1, workspace: "T", prevWorkspace: nil, appBundleId: "com.apple.Safari", appName: "Safari"),
        ])
    }

    @Test func testEventsAreOrderedClosedFirstThenById() {
        let r = diff([3: kitty, 1: on("1", kitty)], [2: kitty, 1: kitty])
        assertEquals(r.events.map(\.eventType), [.windowClosed, .windowMoved, .windowMoved])
    }

    private func entry(_ current: WindowSnapshotEntry?, was: WindowSnapshotEntry?, pending: Bool) -> WindowSnapshot {
        windowSnapshotEntry(current: current, was: was, hasPendingRules: pending).map { [1: $0] } ?? [:]
    }

    @Test func testNewWindowIsAnnouncedOnlyWhereItsRulesLeaveIt() {
        // Bound on the focused workspace "1" while the rules run, then moved to "T" by a rule
        let midRules = diff([:], entry(on("1", kitty), was: nil, pending: true))
        assertEquals(midRules.events, [])
        let settled = diff(midRules.snapshot, entry(kitty, was: midRules.snapshot[1], pending: false))
        assertEquals(settled.events, [
            .windowMoved(windowId: 1, workspace: "T", prevWorkspace: nil, appBundleId: "net.kovidgoyal.kitty", appName: "kitty"),
        ])
    }

    @Test func testKnownWindowWithPendingRulesNeitherMovesNorCloses() {
        // A popup that turned into a window runs the rules again from wherever it was relaid out
        let r = diff([1: kitty], entry(on("1", kitty), was: kitty, pending: true))
        assertEquals(r.events, [])
    }

    @Test func testWindowOutsideAnyWorkspaceKeepsItsEntry() {
        assertEquals(windowSnapshotEntry(current: nil, was: kitty, hasPendingRules: false), kitty)
        assertEquals(windowSnapshotEntry(current: on("1", kitty), was: kitty, hasPendingRules: false), on("1", kitty))
    }
}
