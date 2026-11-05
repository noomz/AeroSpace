@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct PrivateSpaceTest {
    private let journal = PrivateSpaceJournal(session: "boot/login", spaceId: 7, windowIds: [30, 10, 20])

    @Test func testRecoveryRestoresWindowsAndDestroysSpace() {
        assertEquals(
            PrivateSpaceRecovery(journal, session: "boot/login", userVisibleSpaceIds: [1, 3]),
            PrivateSpaceRecovery(windowIdsToRestore: [10, 20, 30], spaceIdToDestroy: 7),
        )
    }

    @Test func testRecoveryIgnoresJournalFromAnotherSession() {
        assertEquals(
            PrivateSpaceRecovery(journal, session: "boot/other-login", userVisibleSpaceIds: []),
            PrivateSpaceRecovery(windowIdsToRestore: [], spaceIdToDestroy: nil),
        )
    }

    @Test func testRecoveryNeverDestroysUserVisibleSpace() {
        assertEquals(
            PrivateSpaceRecovery(journal, session: "boot/login", userVisibleSpaceIds: [1, 7]),
            PrivateSpaceRecovery(windowIdsToRestore: [10, 20, 30], spaceIdToDestroy: nil),
        )
    }

    @Test func testJournalKeepsWindowsStillStrandedAfterRestore() {
        assertEquals(
            journal.afterRestore(stranded: [20, 99]),
            PrivateSpaceJournal(session: "boot/login", spaceId: 7, windowIds: [20]),
        )
    }

    @Test func testJournalIsDoneWhenEveryWindowIsBack() {
        assertEquals(journal.afterRestore(stranded: []), nil)
    }

    @Test func testJournalSurvivesEncoding() throws {
        let data = try JSONEncoder().encode(journal)
        assertEquals(try JSONDecoder().decode(PrivateSpaceJournal.self, from: data), journal)
    }

    @Test func testConfig() {
        assertEquals(parseConfig("").config.hideWindowsInPrivateSpace, true)
        assertEquals(parseConfig("hide-windows-in-private-space = false").config.hideWindowsInPrivateSpace, false)
    }
}
