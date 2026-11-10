@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SafeAreaTest {
    // Main monitor below a 33pt menu bar, with a 32pt SketchyBar wall on top
    private let mainWall = Rect(topLeftX: 0, topLeftY: 33 + 32, width: 1512, height: 949 - 32)
    // Secondary monitor to the left and above main, so its origin is negative. Its wall is 40pt from the top
    private let secondaryWall = Rect(topLeftX: -1920, topLeftY: -300 + 40, width: 1920, height: 1080 - 40)

    @Test func testWindowUnderTopBarIsPushedBelowTheWall() {
        let window = Rect(topLeftX: 100, topLeftY: 10, width: 800, height: 600)
        assertEquals(window.clamped(in: mainWall), Rect(topLeftX: 100, topLeftY: 65, width: 800, height: 600))
    }

    @Test func testEachMonitorUsesItsOwnWall() {
        let window = Rect(topLeftX: -1000, topLeftY: -300, width: 800, height: 600)
        assertEquals(window.clamped(in: secondaryWall), Rect(topLeftX: -1000, topLeftY: -260, width: 800, height: 600))
    }

    @Test func testWindowStraddlingMonitorsLandsInsideTheTargetWall() {
        let window = Rect(topLeftX: -300, topLeftY: 200, width: 800, height: 600)
        assertEquals(window.clamped(in: mainWall), Rect(topLeftX: 0, topLeftY: 200, width: 800, height: 600))
        assertEquals(window.clamped(in: secondaryWall), Rect(topLeftX: -800, topLeftY: 180, width: 800, height: 600))
    }

    @Test func testWindowLargerThanTheWallKeepsItsSizeAndPinsTopLeft() {
        let window = Rect(topLeftX: 50, topLeftY: 0, width: 2000, height: 1200)
        assertEquals(window.clamped(in: mainWall), Rect(topLeftX: 0, topLeftY: 65, width: 2000, height: 1200))
    }

    @Test func testWindowInsideTheWallIsUnchanged() {
        let window = Rect(topLeftX: 200, topLeftY: 300, width: 400, height: 300)
        assertEquals(window.clamped(in: mainWall), window)
    }

    @Test func testWindowTallerThanItsMonitorStaysPutAcrossLayoutPasses() {
        let upper = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let lower = Rect(topLeftX: 500, topLeftY: 1080, width: 1920, height: 1080)
        let upperWall = Rect(topLeftX: 0, topLeftY: 65, width: 1920, height: 1015)
        var window = Rect(topLeftX: 1000, topLeftY: 0, width: 800, height: 2100)
        var frames: [Rect] = []
        for _ in 0 ..< 3 {
            let centerMonitor = lower.contains(window.center) ? lower : upper
            window = window.movedToMonitor(from: centerMonitor, to: upper).clamped(in: upperWall)
            frames.append(window)
        }
        let pinned = Rect(topLeftX: 1000, topLeftY: 65, width: 800, height: 2100)
        assertEquals(frames, [pinned, pinned, pinned])
    }

    @Test func testWindowOnAnotherMonitorMovesToTheSameRelativeSpot() {
        let left = Rect(topLeftX: -1920, topLeftY: 0, width: 1920, height: 1080)
        let main = Rect(topLeftX: 0, topLeftY: 0, width: 2560, height: 1440)
        let window = Rect(topLeftX: -960, topLeftY: 540, width: 400, height: 300)
        assertEquals(window.movedToMonitor(from: left, to: main), Rect(topLeftX: 1280, topLeftY: 720, width: 400, height: 300))
    }

    @Test func testSafeAreaDefaultsToGaps() {
        let result = parseConfig("gaps.outer.top = 40")
        assertEquals(result.errors, [])
        assertEquals(result.config.safeArea, nil)
    }

    @Test func testParseSafeArea() {
        let result = parseConfig(
            """
            [safe-area]
                top = [{ monitor.main = 32 }, 0]
                left = 4
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(
            result.config.safeArea,
            Gaps.Outer(
                left: .constant(4),
                bottom: .constant(0),
                top: .perMonitor([PerMonitorValue(description: .main, value: 32)], default: 0),
                right: .constant(0),
            ),
        )
    }
}
