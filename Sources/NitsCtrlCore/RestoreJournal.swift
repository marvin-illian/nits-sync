import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RestoreEntryState: String, Codable, Hashable, Sendable {
    /// The original value is durable, but no hardware write is confirmed yet.
    case captured
    /// At least one app-owned brightness value has been written.
    case modified
    /// Shutdown or recovery needs to restore the original value.
    case restorePending
}

public struct RestoreJournalEntry: Codable, Hashable, Sendable, Identifiable {
    public var identity: ExternalDisplayIdentity
    public var originalRawValue: UInt16
    public var originalMaximumRawValue: UInt16
    /// Last value whose write and readback were confirmed.
    public var lastWrittenRawValue: UInt16?
    /// Value durably recorded before a hardware write begins.
    public var pendingRawValue: UInt16?
    public var sessionID: UUID
    public var state: RestoreEntryState
    public var capturedAt: Date

    public init(
        identity: ExternalDisplayIdentity,
        originalRawValue: UInt16,
        originalMaximumRawValue: UInt16,
        lastWrittenRawValue: UInt16? = nil,
        pendingRawValue: UInt16? = nil,
        sessionID: UUID,
        state: RestoreEntryState = .captured,
        capturedAt: Date = Date()
    ) {
        self.identity = identity
        self.originalRawValue = originalRawValue
        self.originalMaximumRawValue = originalMaximumRawValue
        self.lastWrittenRawValue = lastWrittenRawValue
        self.pendingRawValue = pendingRawValue
        self.sessionID = sessionID
        self.state = state
        self.capturedAt = capturedAt
    }

    public var id: String {
        "\(sessionID.uuidString.lowercased()):\(identity.stableKey)"
    }

    public mutating func recordWriteIntent(_ rawValue: UInt16) {
        pendingRawValue = rawValue
        state = .modified
    }

    public mutating func confirmWrite(_ rawValue: UInt16) {
        lastWrittenRawValue = rawValue
        pendingRawValue = nil
        state = .modified
    }

    /// Compatibility convenience for callers that already completed a write.
    public mutating func recordWrite(_ rawValue: UInt16) {
        confirmWrite(rawValue)
    }

    public mutating func markRestorePending() {
        state = .restorePending
    }
}

public struct RestoreJournal: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var entries: [RestoreJournalEntry]

    public init(entries: [RestoreJournalEntry] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = []
        for entry in entries {
            upsert(entry)
        }
    }

    public func entry(
        for identity: ExternalDisplayIdentity,
        sessionID: UUID
    ) -> RestoreJournalEntry? {
        entries.first {
            $0.sessionID == sessionID &&
                $0.identity.matchesForPersistence(identity)
        }
    }

    public mutating func upsert(_ entry: RestoreJournalEntry) {
        if let index = entries.firstIndex(where: {
            $0.sessionID == entry.sessionID &&
                $0.identity.matchesForPersistence(entry.identity)
        }) {
            var replacement = entry
            if entries[index].identity.persistenceSpecificity >
                replacement.identity.persistenceSpecificity {
                replacement.identity = entries[index].identity
            }
            entries[index] = replacement
        } else {
            entries.append(entry)
        }
    }

    @discardableResult
    public mutating func removeEntry(
        for identity: ExternalDisplayIdentity,
        sessionID: UUID
    ) -> RestoreJournalEntry? {
        guard let index = entries.firstIndex(where: {
            $0.sessionID == sessionID &&
                $0.identity.matchesForPersistence(identity)
        }) else {
            return nil
        }
        return entries.remove(at: index)
    }

    fileprivate var sortedForPersistence: RestoreJournal {
        RestoreJournal(entries: entries.sorted {
            if $0.identity.stableKey == $1.identity.stableKey {
                return $0.sessionID.uuidString < $1.sessionID.uuidString
            }
            return $0.identity.stableKey < $1.identity.stableKey
        })
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported restore journal schema version \(schemaVersion)"
            )
        }

        self.schemaVersion = schemaVersion
        entries = []
        for entry in try container.decode([RestoreJournalEntry].self, forKey: .entries) {
            upsert(entry)
        }
    }
}

public enum RestoreJournalStoreError: Error, Equatable, Sendable {
    case systemCallFailed(operation: String, code: Int32)
}

extension RestoreJournalStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .systemCallFailed(operation, code):
            let description = String(cString: strerror(code))
            return "\(operation) failed (errno \(code): \(description))"
        }
    }
}

/// File-backed restore storage with an injectable URL for tests.
///
/// Saves use a same-directory temporary file, synchronize it, atomically rename
/// it over the destination, then synchronize the containing directory.
public struct RestoreJournalStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public func load() throws -> RestoreJournal {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RestoreJournal()
        }
        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(RestoreJournal.self, from: data)
    }

    public func save(_ journal: RestoreJournal) throws {
        let data = try Self.encoder.encode(journal.sortedForPersistence)
        try Self.durablyReplace(fileURL: fileURL, with: data)
    }

    @discardableResult
    public func upsert(_ entry: RestoreJournalEntry) throws -> RestoreJournal {
        var journal = try load()
        journal.upsert(entry)
        try save(journal)
        return journal
    }

    @discardableResult
    public func removeEntry(
        for identity: ExternalDisplayIdentity,
        sessionID: UUID
    ) throws -> RestoreJournal {
        var journal = try load()
        journal.removeEntry(for: identity, sessionID: sessionID)
        if journal.entries.isEmpty {
            try clear()
        } else {
            try save(journal)
        }
        return journal
    }

    public func clear() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let result = Self.removeFile(atPath: fileURL.path)
        if result == -1, errno != ENOENT {
            throw RestoreJournalStoreError.systemCallFailed(
                operation: "unlink journal",
                code: errno
            )
        }
        if result == 0 {
            try Self.synchronizeDirectory(directoryURL)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func durablyReplace(fileURL: URL, with data: Data) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        var descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw RestoreJournalStoreError.systemCallFailed(
                operation: "open temporary journal",
                code: errno
            )
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 {
                _ = close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written == -1, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw RestoreJournalStoreError.systemCallFailed(
                        operation: "write temporary journal",
                        code: errno
                    )
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }

        try fullySynchronize(descriptor, operation: "synchronize temporary journal")

        guard close(descriptor) == 0 else {
            let code = errno
            descriptor = -1
            throw RestoreJournalStoreError.systemCallFailed(
                operation: "close temporary journal",
                code: code
            )
        }
        descriptor = -1

        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw RestoreJournalStoreError.systemCallFailed(
                operation: "replace journal",
                code: errno
            )
        }
        shouldRemoveTemporaryFile = false

        try synchronizeDirectory(directoryURL)
    }

    private static func fullySynchronize(_ descriptor: Int32, operation: String) throws {
        #if os(macOS)
        if fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        #endif

        guard fsync(descriptor) == 0 else {
            throw RestoreJournalStoreError.systemCallFailed(operation: operation, code: errno)
        }
    }

    private static func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw RestoreJournalStoreError.systemCallFailed(
                operation: "open journal directory",
                code: errno
            )
        }
        defer { _ = close(descriptor) }

        guard fsync(descriptor) == 0 else {
            throw RestoreJournalStoreError.systemCallFailed(
                operation: "synchronize journal directory",
                code: errno
            )
        }
    }

    private static func removeFile(atPath path: String) -> Int32 {
        #if canImport(Darwin)
        Darwin.unlink(path)
        #elseif canImport(Glibc)
        Glibc.unlink(path)
        #else
        -1
        #endif
    }
}
