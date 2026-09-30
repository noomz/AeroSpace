@testable import AppBundle
import Common
import XCTest

final class WindowEventsDiffTest: XCTestCase {
    private let kitty = WindowSnapshotEntry(workspace: "T", appBundleId: "net.kovidgoyal.kitty", appName: "kitty")

    private func diff(
        _ old: WindowSnapshot,
        _ new: WindowSnapshot,
        isLocked: Bool = false,
        sticky: Set<UInt32> = [],
        isFirstDiff: Bool = false,
    ) -> (events: [ServerEvent], snapshot: WindowSnapshot) {
        diffWindowSnapshots(old: old, new: new, isLocked: isLocked, sticky: sticky, isFirstDiff: isFirstDiff)
    }

    private func on(_ workspace: String, _ e: WindowSnapshotEntry) -> WindowSnapshotEntry {
        WindowSnapshotEntry(workspace: workspace, appBundleId: e.appBundleId, appName: e.appName)
    }

    func testFirstAppearanceHasNoPrevWorkspace() {
        let r = diff([:], [1: kitty])
        assertEquals(r.events, [
            .windowMoved(windowId: 1, workspace: "T", prevWorkspace: nil, appBundleId: "net.kovidgoyal.kitty", appName: "kitty"),
        ])
        assertEquals(r.snapshot, [1: kitty])
    }

    func testMoveCarriesPrevWorkspace() {
        let r = diff([1: on("1", kitty)], [1: kitty])
        assertEquals(r.events, [
            .windowMoved(windowId: 1, workspace: "T", prevWorkspace: "1", appBundleId: "net.kovidgoyal.kitty", appName: "kitty"),
        ])
    }

    func testCloseCarriesTheLastWorkspace() {
        let r = diff([1: kitty], [:])
        assertEquals(r.events, [.windowClosed(windowId: 1, workspace: "T", appBundleId: "net.kovidgoyal.kitty")])
        assertEquals(r.snapshot, [:])
    }

    func testWithinWorkspaceRebindIsSilent() {
        // Same workspace in both snapshots, whatever happened to the tree in between
        let r = diff([1: kitty, 2: on("1", kitty)], [1: kitty, 2: on("1", kitty)])
        assertEquals(r.events, [])
    }

    func testLockFreezesTheSnapshotSoUnlockEmitsNoBurst() {
        let before: WindowSnapshot = [1: kitty, 2: on("1", kitty)]
        let locked = diff(before, [:], isLocked: true) // every window looks closed behind the lock screen
        assertEquals(locked.events, [])
        assertEquals(locked.snapshot, before)
        let unlocked = diff(locked.snapshot, before) // cache restored every window where it was
        assertEquals(unlocked.events, [])
    }

    func testStickyNeverMovesButStillCloses() {
        let bitwarden = WindowSnapshotEntry(workspace: "1", appBundleId: "com.bitwarden.desktop", appName: "Bitwarden")
        let moved = diff([7: bitwarden], [7: on("2", bitwarden)], sticky: [7])
        assertEquals(moved.events, [])
        assertEquals(moved.snapshot, [7: on("2", bitwarden)]) // the entry updates silently
        assertEquals(diff([:], [7: bitwarden], sticky: [7]).events, [])
        assertEquals(diff([7: bitwarden], [:], sticky: []).events, [
            .windowClosed(windowId: 7, workspace: "1", appBundleId: "com.bitwarden.desktop"),
        ])
    }

    func testStartupSeedsSilently() {
        let r = diff([:], [1: kitty, 2: on("1", kitty)], isFirstDiff: true)
        assertEquals(r.events, [])
        assertEquals(r.snapshot, [1: kitty, 2: on("1", kitty)])
    }

    func testRecycledWindowIdIsACloseAndAFirstAppearance() {
        let safari = WindowSnapshotEntry(workspace: "T", appBundleId: "com.apple.Safari", appName: "Safari")
        let r = diff([1: kitty], [1: safari])
        assertEquals(r.events, [
            .windowClosed(windowId: 1, workspace: "T", appBundleId: "net.kovidgoyal.kitty"),
            .windowMoved(windowId: 1, workspace: "T", prevWorkspace: nil, appBundleId: "com.apple.Safari", appName: "Safari"),
        ])
    }

    func testEventsAreOrderedClosedFirstThenById() {
        let r = diff([3: kitty, 1: on("1", kitty)], [2: kitty, 1: kitty])
        assertEquals(r.events.map(\.eventType), [.windowClosed, .windowMoved, .windowMoved])
    }
}
