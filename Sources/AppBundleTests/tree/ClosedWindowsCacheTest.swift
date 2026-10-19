@testable import AppBundle
import XCTest

@MainActor
final class ClosedWindowsCacheTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
        onScreenUnlocked()
    }

    // https://github.com/nikitabobko/AeroSpace/issues/2234
    func testDontRestoreCacheIfScreenWasNeverLocked() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded() // The window is about to die
        window.unbindFromParent()

        // macOS reuses window IDs. A brand new window may get the ID of a previously closed window
        let newWindow = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: newWindow)
        XCTAssertFalse(restored)
    }

    func testRestoreCacheIfScreenWasLockedAfterCaching() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        window.unbindFromParent()

        onScreenLocked()
        onScreenUnlocked()

        let reappeared = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: reappeared)
        XCTAssertTrue(restored)
    }

    func testRestoreCacheIfCachedWhileScreenIsLocked() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        onScreenLocked()
        cacheClosedWindowIfNeeded() // Lock screen makes AeroSpace think that the window died
        window.unbindFromParent()
        onScreenUnlocked()

        let reappeared = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: reappeared)
        XCTAssertTrue(restored)
    }

    func testDontRestoreCacheCapturedAfterUnlock() async throws {
        let workspace = Workspace.get(byName: name)
        onScreenLocked()
        onScreenUnlocked()

        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded() // Genuine close after the unlock
        window.unbindFromParent()

        let newWindow = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: newWindow)
        XCTAssertFalse(restored)
    }

    func testResetCacheForgetsScreenLock() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        window.unbindFromParent()
        onScreenLocked()
        onScreenUnlocked()

        resetClosedWindowsCache() // E.g. the user ran a command that changed the layout
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        window2.unbindFromParent()

        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: newWindow)
        XCTAssertFalse(restored)
    }

    func testRestoreWindowSavedAfterMissingSibling() async throws {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = focus.workspace
        let window1 = TestWindow.new(id: 1, parent: workspaceA.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspaceA.rootTilingContainer)

        onScreenLocked()
        cacheClosedWindowIfNeeded()
        window1.unbindFromParent()
        window2.unbindFromParent()
        onScreenUnlocked()

        // Windows re-register one at a time, each one bound to the focused workspace first
        let reappeared2 = TestWindow.new(id: 2, parent: workspaceB.rootTilingContainer)
        try await assertRestored(reappeared2)
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
        assertEquals(workspaceB.rootTilingContainer.layoutDescription, .h_tiles([]))

        let reappeared1 = TestWindow.new(id: 1, parent: workspaceB.rootTilingContainer)
        try await assertRestored(reappeared1)
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(workspaceB.rootTilingContainer.layoutDescription, .h_tiles([]))
    }

    func testRestoreWindowInNestedContainerWithMissingSibling() async throws {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = focus.workspace
        let window1 = TestWindow.new(id: 1, parent: workspaceA.rootTilingContainer)
        let nested = TilingContainer.newVTiles(
            parent: workspaceA.rootTilingContainer,
            adaptiveWeight: 1,
            index: INDEX_BIND_LAST,
        )
        let window2 = TestWindow.new(id: 2, parent: nested)
        let window3 = TestWindow.new(id: 3, parent: nested)

        onScreenLocked()
        cacheClosedWindowIfNeeded()
        window1.unbindFromParent()
        window2.unbindFromParent()
        window3.unbindFromParent()
        onScreenUnlocked()

        let reappeared3 = TestWindow.new(id: 3, parent: workspaceB.rootTilingContainer)
        try await assertRestored(reappeared3)
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.v_tiles([.window(3)])]))
        assertEquals(workspaceB.rootTilingContainer.layoutDescription, .h_tiles([]))

        let reappeared1 = TestWindow.new(id: 1, parent: workspaceB.rootTilingContainer)
        try await assertRestored(reappeared1)
        assertEquals(
            workspaceA.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(3)])]),
        )

        let reappeared2 = TestWindow.new(id: 2, parent: workspaceB.rootTilingContainer)
        try await assertRestored(reappeared2)
        assertEquals(
            workspaceA.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
        )
        assertEquals(workspaceB.rootTilingContainer.layoutDescription, .h_tiles([]))
    }

    func testEmptyNestedContainerOfMissingWindowsIsNormalizedAway() async throws {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = focus.workspace
        let nested = TilingContainer.newVTiles(
            parent: workspaceA.rootTilingContainer,
            adaptiveWeight: 1,
            index: INDEX_BIND_LAST,
        )
        let window1 = TestWindow.new(id: 1, parent: nested)
        let window2 = TestWindow.new(id: 2, parent: workspaceA.rootTilingContainer)

        onScreenLocked()
        cacheClosedWindowIfNeeded()
        window1.unbindFromParent()
        window2.unbindFromParent()
        onScreenUnlocked()

        let reappeared2 = TestWindow.new(id: 2, parent: workspaceB.rootTilingContainer)
        try await assertRestored(reappeared2)
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.v_tiles([]), .window(2)]))
        workspaceA.normalizeContainers()
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
    }

    func testRestoreFloatingWindowWhileTiledSiblingIsMissing() async throws {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = focus.workspace
        let window1 = TestWindow.new(id: 1, parent: workspaceA.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspaceA.floatingWindowsContainer)

        onScreenLocked()
        cacheClosedWindowIfNeeded()
        window1.unbindFromParent()
        window2.unbindFromParent()
        onScreenUnlocked()

        let reappeared2 = TestWindow.new(id: 2, parent: workspaceB.rootTilingContainer)
        try await assertRestored(reappeared2)
        assertEquals(workspaceA.floatingWindows.map(\.windowId), [2])
        assertEquals(workspaceB.rootTilingContainer.layoutDescription, .h_tiles([]))
    }

    private func assertRestored(_ window: Window, file: StaticString = #filePath, line: UInt = #line) async throws {
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window)
        XCTAssertTrue(restored, file: file, line: line)
    }
}
