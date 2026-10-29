import Foundation
import NitsCtrlCore

enum ApplicationSupport {
    static let folderName = "Nits Sync"
    private static let legacyFolderNames = ["nits-ctrl"]

    static var directoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private static var legacyDirectoryURLs: [URL] {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return legacyFolderNames.map { base.appendingPathComponent($0, isDirectory: true) }
    }

    private static var candidateDirectoryURLs: [URL] {
        [directoryURL] + legacyDirectoryURLs
    }

    static var profilesURL: URL {
        directoryURL.appendingPathComponent("display-profiles.json")
    }

    static var existingProfilesURL: URL {
        existingFileURL(for: "display-profiles.json")
    }

    static var existingRestoreJournalURL: URL {
        existingFileURL(for: "restore-journal.json")
    }

    private static func existingFileURL(for fileName: String) -> URL {
        let directCandidate = directoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: directCandidate.path) {
            return directCandidate
        }
        let legacyCandidate = legacyDirectoryURLs
            .map { $0.appendingPathComponent(fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return legacyCandidate ?? directCandidate
    }

    static func removeAllGeneratedFiles() throws {
        for target in candidateDirectoryURLs {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
    }
}

final class DisplayProfileRepository {
    private let fileURL: URL
    private var store: DisplayProfileStore

    init(fileURL: URL = ApplicationSupport.profilesURL) {
        self.fileURL = fileURL
        store = DisplayProfileStore()
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? Self.decoder.decode(DisplayProfileStore.self, from: data) {
            store = decoded
        } else {
            // Keep an unreadable file (e.g. from a newer build) instead of
            // letting the first profile update overwrite every calibration.
            let backupURL = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        }
    }

    func profile(for identity: ExternalDisplayIdentity) -> DisplayProfile? {
        store.profile(for: identity)
    }

    func upsert(_ profile: DisplayProfile) throws {
        store.upsert(profile)
        try persist()
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(store)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

enum Preferences {
    static let syncEnabled = "syncEnabled"
    static let autoHideIcon = "autoHideIcon"
    static let lowLatencySync = "lowLatencySync"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            syncEnabled: true,
            autoHideIcon: false,
            lowLatencySync: false,
        ])
    }
}
