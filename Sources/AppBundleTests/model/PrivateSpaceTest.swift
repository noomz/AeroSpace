@testable import AppBundle
import Common
import XCTest

final class PrivateSpaceTest: XCTestCase {
    private let journal = PrivateSpaceJournal(session: "boot/login", spaceId: 7, windowIds: [30, 10, 20])

    func testRecoveryRestoresWindowsAndDestroysSpace() {
        assertEquals(
            PrivateSpaceRecovery(journal, session: "boot/login", userVisibleSpaceIds: [1, 3]),
            PrivateSpaceRecovery(windowIdsToRestore: [10, 20, 30], spaceIdToDestroy: 7),
        )
    }

    func testRecoveryIgnoresJournalFromAnotherSession() {
        assertEquals(
            PrivateSpaceRecovery(journal, session: "boot/other-login", userVisibleSpaceIds: []),
            PrivateSpaceRecovery(windowIdsToRestore: [], spaceIdToDestroy: nil),
        )
    }

    func testRecoveryNeverDestroysUserVisibleSpace() {
        assertEquals(
            PrivateSpaceRecovery(journal, session: "boot/login", userVisibleSpaceIds: [1, 7]),
            PrivateSpaceRecovery(windowIdsToRestore: [10, 20, 30], spaceIdToDestroy: nil),
        )
    }

    func testJournalKeepsWindowsStillStrandedAfterRestore() {
        assertEquals(
            journal.afterRestore(stranded: [20, 99]),
            PrivateSpaceJournal(session: "boot/login", spaceId: 7, windowIds: [20]),
        )
    }

    func testJournalIsDoneWhenEveryWindowIsBack() {
        assertEquals(journal.afterRestore(stranded: []), nil)
    }

    func testJournalSurvivesEncoding() throws {
        let data = try JSONEncoder().encode(journal)
        assertEquals(try JSONDecoder().decode(PrivateSpaceJournal.self, from: data), journal)
    }

    @MainActor
    func testConfig() {
        assertEquals(parseConfig("").config.hideWindowsInPrivateSpace, true)
        assertEquals(parseConfig("hide-windows-in-private-space = false").config.hideWindowsInPrivateSpace, false)
    }
}
