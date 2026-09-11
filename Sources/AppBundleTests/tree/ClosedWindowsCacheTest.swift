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
}
