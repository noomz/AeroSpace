@testable import AppBundle
import Common
import XCTest

final class ThreadGuardedValueTest: XCTestCase {
    func testThreadGuardedIfAliveReturnsNilAfterDestroy() {
        $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: 42, idForDebug: "test")) {
            let value = ThreadGuardedValue(1)
            XCTAssertEqual(value.threadGuardedIfAlive, 1)
            value.destroy()
            XCTAssertNil(value.threadGuardedIfAlive)
        }
    }
}
