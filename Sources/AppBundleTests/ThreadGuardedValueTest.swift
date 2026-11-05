@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct ThreadGuardedValueTest {
    @Test func testThreadGuardedIfAliveReturnsNilAfterDestroy() {
        $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: 42, idForDebug: "test")) {
            let value = ThreadGuardedValue(1)
            assertEquals(value.threadGuardedIfAlive, 1)
            value.destroy()
            assertNil(value.threadGuardedIfAlive)
        }
    }
}
