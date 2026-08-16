import Foundation
import XCTest
@testable import NitsCtrlCore

final class RestoreJournalTests: XCTestCase {
    func testWriteIntentAndConfirmationRetainCrashRecoveryValues() {
        var entry = RestoreJournalEntry(
            identity: ExternalDisplayIdentity(
                vendorID: 1,
                productID: 2,
                serialNumber: 3
            ),
            originalRawValue: 42,
            originalMaximumRawValue: 100,
            sessionID: UUID()
        )
        entry.recordWriteIntent(55)
        XCTAssertEqual(entry.pendingRawValue, 55)
        XCTAssertNil(entry.lastWrittenRawValue)

        entry.confirmWrite(55)
        XCTAssertNil(entry.pendingRawValue)
        XCTAssertEqual(entry.lastWrittenRawValue, 55)

        entry.recordWriteIntent(70)
        XCTAssertEqual(entry.lastWrittenRawValue, 55)
        XCTAssertEqual(entry.pendingRawValue, 70)
    }

    func testRapidUnverifiedWritesRemainRecognizableUntilNewestConfirmation() {
        var entry = RestoreJournalEntry(
            identity: ExternalDisplayIdentity(
                vendorID: 1,
                productID: 2,
                serialNumber: 3
            ),
            originalRawValue: 100,
            originalMaximumRawValue: 100,
            sessionID: UUID()
        )

        entry.recordWriteIntent(8)
        entry.recordWriteIntent(12)
        entry.recordWriteIntent(20)

        XCTAssertEqual(entry.pendingRawValue, 20)
        XCTAssertEqual(entry.knownAppWrittenRawValues, Set([8, 12, 20]))

        entry.confirmWrite(20)

        XCTAssertNil(entry.pendingRawValue)
        XCTAssertNil(entry.unverifiedRawValues)
        XCTAssertEqual(entry.knownAppWrittenRawValues, Set([20]))
    }

    func testMissingJournalLoadsAsEmpty() throws {
        try withTemporaryStore { store, _ in
            let journal = try store.load()
            XCTAssertEqual(journal.schemaVersion, RestoreJournal.currentSchemaVersion)
            XCTAssertTrue(journal.entries.isEmpty)
        }
    }

    func testEntryPersistsAllRestorationFields() throws {
        try withTemporaryStore { store, fileURL in
            let identity = ExternalDisplayIdentity(
                vendorID: 10,
                productID: 20,
                serialNumber: 30
            )
            let sessionID = UUID(uuidString: "875386B5-1B29-4A44-BCA4-7D978077656C")!
            var entry = RestoreJournalEntry(
                identity: identity,
                originalRawValue: 73,
                originalMaximumRawValue: 100,
                sessionID: sessionID,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            try store.upsert(entry)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            entry.recordWrite(42)
            entry.markRestorePending()
            try store.upsert(entry)

            let restored = try XCTUnwrap(
                store.load().entry(for: identity, sessionID: sessionID)
            )
            XCTAssertEqual(restored.originalRawValue, 73)
            XCTAssertEqual(restored.originalMaximumRawValue, 100)
            XCTAssertEqual(restored.lastWrittenRawValue, 42)
            XCTAssertEqual(restored.state, .restorePending)
            XCTAssertEqual(restored.sessionID, sessionID)
            XCTAssertEqual(restored.capturedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        }
    }

    func testRemovingOneEntryLeavesOtherSessionsIntact() throws {
        try withTemporaryStore { store, _ in
            let identity = ExternalDisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)
            let firstSession = UUID()
            let secondSession = UUID()

            try store.save(RestoreJournal(entries: [
                RestoreJournalEntry(
                    identity: identity,
                    originalRawValue: 10,
                    originalMaximumRawValue: 100,
                    sessionID: firstSession
                ),
                RestoreJournalEntry(
                    identity: identity,
                    originalRawValue: 20,
                    originalMaximumRawValue: 100,
                    sessionID: secondSession
                ),
            ]))

            let journal = try store.removeEntry(for: identity, sessionID: firstSession)
            XCTAssertNil(journal.entry(for: identity, sessionID: firstSession))
            XCTAssertNotNil(journal.entry(for: identity, sessionID: secondSession))
            XCTAssertEqual(try store.load(), journal)
        }
    }

    func testRemovingLastEntryRemovesJournalFile() throws {
        try withTemporaryStore { store, fileURL in
            let identity = ExternalDisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)
            let sessionID = UUID()
            try store.upsert(RestoreJournalEntry(
                identity: identity,
                originalRawValue: 10,
                originalMaximumRawValue: 100,
                sessionID: sessionID
            ))

            let journal = try store.removeEntry(for: identity, sessionID: sessionID)
            XCTAssertTrue(journal.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testLegacyIdentityCanBeRecoveredAndMigratedByAlphanumericSerial() throws {
        let sessionID = UUID()
        let legacyIdentity = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            edidHash: "same-edid",
            transportPath: "same-port"
        )
        let currentIdentity = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            alphanumericSerialNumber: "panel-serial",
            edidHash: "same-edid",
            transportPath: "same-port"
        )
        var journal = RestoreJournal(entries: [RestoreJournalEntry(
            identity: legacyIdentity,
            originalRawValue: 40,
            originalMaximumRawValue: 100,
            sessionID: sessionID
        )])

        var migrated = try XCTUnwrap(
            journal.entry(for: currentIdentity, sessionID: sessionID)
        )
        migrated.identity = currentIdentity
        migrated.recordWrite(55)
        journal.upsert(migrated)

        XCTAssertEqual(journal.entries.count, 1)
        XCTAssertEqual(journal.entries[0].identity, currentIdentity)
        XCTAssertEqual(journal.entries[0].lastWrittenRawValue, 55)
        XCTAssertNotNil(journal.removeEntry(
            for: legacyIdentity,
            sessionID: sessionID
        ))
        XCTAssertTrue(journal.entries.isEmpty)
    }

    func testClearRemovesJournalAndTemporaryFiles() throws {
        try withTemporaryStore { store, fileURL in
            try store.save(RestoreJournal())
            try store.clear()

            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            let siblings = try FileManager.default.contentsOfDirectory(
                atPath: fileURL.deletingLastPathComponent().path
            )
            XCTAssertFalse(siblings.contains { $0.hasSuffix(".tmp") })
        }
    }

    private func withTemporaryStore(
        _ body: (RestoreJournalStore, URL) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NitsCtrlCoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("restore-journal.json")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try body(RestoreJournalStore(fileURL: fileURL), fileURL)
    }
}
