@testable import AppBundle
import AppKit
import Common
import Testing

private struct StaleMonitorInfo: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 2
    let name = "Disconnected"
    let rect = Rect(topLeftX: 5000, topLeftY: 0, width: 1920, height: 1080)
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let isMain = false
}

@MainActor
@Suite(.serializedGlobally)
struct MonitorTest {
    init() { setUpWorkspacesForTests() }

    @Test func testStaleMonitorInfoResolvesToClosestMonitor() {
        let main = mainMonitorInfo.toMonitorOrRearrangeMonitors()
        #expect(StaleMonitorInfo().toMonitorOrRearrangeMonitors() === main)
        #expect(StaleMonitorInfo().visibleWorkspace === mainMonitorInfo.visibleWorkspace)
        #expect(Monitor.all.count == 1)
    }
}
