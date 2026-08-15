import Foundation

/// Hardware-derived values that identify an external display across reconnects.
///
/// `stableKey` deliberately prefers a real numeric serial number, followed by
/// the EDID's alphanumeric serial. When a display publishes neither, callers
/// should supply the ColorSync UUID and transport path whenever possible so two
/// identical panels are not conflated.
public struct ExternalDisplayIdentity: Codable, Hashable, Sendable, Identifiable {
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32?
    public let alphanumericSerialNumber: String?
    public let displayUUID: UUID?
    public let edidHash: String?
    public let transportPath: String?

    public init(
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32? = nil,
        alphanumericSerialNumber: String? = nil,
        displayUUID: UUID? = nil,
        edidHash: String? = nil,
        transportPath: String? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.alphanumericSerialNumber = alphanumericSerialNumber
        self.displayUUID = displayUUID
        self.edidHash = edidHash
        self.transportPath = transportPath
    }

    public var id: String { stableKey }

    /// A deterministic key suitable for persisted profile lookup.
    public var stableKey: String {
        let model = "v\(Self.hex(vendorID))-p\(Self.hex(productID))"

        if let serialNumber, serialNumber != 0, serialNumber != UInt32.max {
            return "\(model)-s\(Self.hex(serialNumber))"
        }

        if let serial = Self.normalized(alphanumericSerialNumber) {
            return "\(model)-a\(Self.keyComponent(serial))"
        }

        return legacyStableKey
    }

    /// The key emitted by releases that predate alphanumeric-serial support.
    /// It remains available solely to find and safely migrate existing files.
    public var legacyStableKey: String {
        let model = "v\(Self.hex(vendorID))-p\(Self.hex(productID))"

        if let serialNumber, serialNumber != 0, serialNumber != UInt32.max {
            return "\(model)-s\(Self.hex(serialNumber))"
        }

        if let displayUUID {
            return "\(model)-u\(displayUUID.uuidString.lowercased())"
        }

        let normalizedEDID = Self.normalized(edidHash)
        let normalizedPath = Self.normalized(transportPath)

        if let normalizedEDID, let normalizedPath {
            return "\(model)-e\(Self.keyComponent(normalizedEDID))-t\(Self.keyComponent(normalizedPath))"
        }
        if let normalizedPath {
            return "\(model)-t\(Self.keyComponent(normalizedPath))"
        }
        if let normalizedEDID {
            return "\(model)-e\(Self.keyComponent(normalizedEDID))"
        }

        return model
    }

    /// Matches a current hardware identity to an identity loaded from an older
    /// profile or restore journal without conflating two known serials.
    ///
    /// If both sides publish alphanumeric serials, they must agree. The legacy
    /// EDID/path key is considered only when exactly one side lacks that field,
    /// which is the shape produced by an older persisted file.
    public func matchesForPersistence(_ other: ExternalDisplayIdentity) -> Bool {
        guard vendorID == other.vendorID, productID == other.productID else {
            return false
        }

        let numericSerial = validNumericSerial
        let otherNumericSerial = other.validNumericSerial
        if numericSerial != nil || otherNumericSerial != nil {
            return numericSerial != nil && numericSerial == otherNumericSerial
        }

        let alphanumericSerial = Self.normalized(alphanumericSerialNumber)
        let otherAlphanumericSerial = Self.normalized(other.alphanumericSerialNumber)
        if let alphanumericSerial, let otherAlphanumericSerial {
            return alphanumericSerial == otherAlphanumericSerial
        }
        if alphanumericSerial != nil || otherAlphanumericSerial != nil {
            return legacyStableKey == other.legacyStableKey
        }

        return stableKey == other.stableKey
    }

    /// Indicates that two same-model displays may be impossible to distinguish.
    public var isAmbiguous: Bool {
        let hasSerial = validNumericSerial != nil ||
            Self.normalized(alphanumericSerialNumber) != nil
        return !hasSerial && displayUUID == nil && Self.normalized(transportPath) == nil
    }

    var persistenceSpecificity: Int {
        if validNumericSerial != nil { return 3 }
        if Self.normalized(alphanumericSerialNumber) != nil { return 2 }
        if displayUUID != nil { return 1 }
        return 0
    }

    private var validNumericSerial: UInt32? {
        guard let serialNumber,
              serialNumber != 0,
              serialNumber != UInt32.max else { return nil }
        return serialNumber
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "%08x", value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func keyComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct DisplayProfile: Codable, Hashable, Sendable, Identifiable {
    public var identity: ExternalDisplayIdentity
    public var name: String?
    public var calibration: CalibrationCurve
    public var isEnabled: Bool

    public init(
        identity: ExternalDisplayIdentity,
        name: String? = nil,
        calibration: CalibrationCurve,
        isEnabled: Bool = true
    ) {
        self.identity = identity
        self.name = name
        self.calibration = calibration
        self.isEnabled = isEnabled
    }

    public var id: String { identity.stableKey }
}

/// Persistable shape for all per-display settings.
public struct DisplayProfileStore: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var profiles: [DisplayProfile]

    public init(profiles: [DisplayProfile] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.profiles = []
        for profile in profiles {
            upsert(profile)
        }
    }

    public func profile(for identity: ExternalDisplayIdentity) -> DisplayProfile? {
        guard var profile = profiles.first(where: {
            $0.identity.matchesForPersistence(identity)
        }) else { return nil }

        // Return the richer current identity so the next ordinary settings
        // update naturally migrates an older profile on disk.
        if identity.persistenceSpecificity > profile.identity.persistenceSpecificity {
            profile.identity = identity
        }
        return profile
    }

    public mutating func upsert(_ profile: DisplayProfile) {
        if let index = profiles.firstIndex(where: {
            $0.identity.matchesForPersistence(profile.identity)
        }) {
            var replacement = profile
            if profiles[index].identity.persistenceSpecificity >
                replacement.identity.persistenceSpecificity {
                replacement.identity = profiles[index].identity
            }
            profiles[index] = replacement
        } else {
            profiles.append(profile)
        }
    }

    @discardableResult
    public mutating func removeProfile(for identity: ExternalDisplayIdentity) -> DisplayProfile? {
        guard let index = profiles.firstIndex(where: {
            $0.identity.matchesForPersistence(identity)
        }) else {
            return nil
        }
        return profiles.remove(at: index)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profiles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported display profile schema version \(schemaVersion)"
            )
        }

        self.schemaVersion = schemaVersion
        profiles = []
        for profile in try container.decode([DisplayProfile].self, forKey: .profiles) {
            upsert(profile)
        }
    }
}
