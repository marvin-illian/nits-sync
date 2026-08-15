import Foundation

public enum SyncClamp: String, Codable, Hashable, Sendable {
    case none
    case minimum
    case maximum
}

public struct DisplaySyncTarget: Codable, Hashable, Sendable, Identifiable {
    public let identity: ExternalDisplayIdentity
    public let requestedNits: Double
    public let estimatedNits: Double
    public let rawValue: UInt16
    public let clamp: SyncClamp

    public init(
        identity: ExternalDisplayIdentity,
        requestedNits: Double,
        estimatedNits: Double,
        rawValue: UInt16,
        clamp: SyncClamp
    ) {
        self.identity = identity
        self.requestedNits = requestedNits
        self.estimatedNits = estimatedNits
        self.rawValue = rawValue
        self.clamp = clamp
    }

    public var id: String { identity.stableKey }
}

/// Stateless nits-based coordination. Each display follows the source until it
/// reaches its own calibrated minimum or maximum, then remains clamped there.
public struct SyncPolicy: Sendable {
    public init() {}

    public func target(
        for sourceNits: Double,
        profile: DisplayProfile
    ) -> DisplaySyncTarget? {
        guard profile.isEnabled, sourceNits.isFinite else { return nil }

        let curve = profile.calibration
        let clamp: SyncClamp
        if sourceNits < curve.minimumNits {
            clamp = .minimum
        } else if sourceNits > curve.maximumNits {
            clamp = .maximum
        } else {
            clamp = .none
        }

        guard let rawValue = curve.quantizedRawValue(forNits: sourceNits) else {
            return nil
        }

        return DisplaySyncTarget(
            identity: profile.identity,
            requestedNits: sourceNits,
            estimatedNits: curve.nits(forRawValue: rawValue),
            rawValue: rawValue,
            clamp: clamp
        )
    }

    public func targets(
        for sourceNits: Double,
        profiles: [DisplayProfile]
    ) -> [DisplaySyncTarget] {
        profiles.compactMap { target(for: sourceNits, profile: $0) }
    }
}
