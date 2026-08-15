import CryptoKit
import Foundation
@preconcurrency import CNitsCtrlDDC
import NitsCtrlCore

/// A discovered external monitor and its opaque DDC service handle.
public final class DDCDisplay: @unchecked Sendable, Identifiable {
    public let id: String
    public let name: String
    public let manufacturerID: String
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32?
    public let alphanumericSerial: String?
    public let edidUUID: UUID?
    public let edidData: Data
    public let identity: ExternalDisplayIdentity
    public let registryEntryID: UInt64
    public let registryPath: String
    public let ddcChipAddress: UInt32
    public let hasValidEDID: Bool

    fileprivate let service: CNDDCDisplay

    fileprivate init(service: CNDDCDisplay) {
        self.service = service
        edidData = service.edidData
        manufacturerID = service.manufacturerID
        vendorID = UInt32(service.manufacturerCode)
        productID = UInt32(service.productCode)
        registryEntryID = service.registryEntryID
        registryPath = service.registryPath
        ddcChipAddress = service.chipAddress
        hasValidEDID = service.edidIsValid

        let rawSerial = service.numericSerialNumber
        if rawSerial == 0 || rawSerial == UInt32.max {
            serialNumber = nil
        } else {
            serialNumber = rawSerial
        }

        alphanumericSerial = Self.nonempty(service.alphanumericSerialNumber)
        name = Self.nonempty(service.productName) ?? "External Display"

        let edidHash = edidData.isEmpty ? nil : Self.sha256Hex(edidData)
        edidUUID = edidData.isEmpty ? nil : Self.uuidFromEDID(edidData)

        // A hash-derived UUID is useful as compact metadata but is not a
        // ColorSync UUID and cannot distinguish two panels with identical
        // EDIDs. Keep it out of displayUUID so the core identity also includes
        // the transport path when a real serial is absent.
        identity = ExternalDisplayIdentity(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            alphanumericSerialNumber: alphanumericSerial,
            displayUUID: nil,
            edidHash: edidHash,
            transportPath: Self.nonempty(registryPath)
        )
        id = identity.stableKey
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func uuidFromEDID(_ data: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        // Use the custom UUID version while retaining the deterministic EDID
        // digest payload.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public enum DDCTransportError: LocalizedError, Sendable {
    case operationFailed(operation: String, displayID: String?, reason: String)
    case invalidBrightnessReply(displayID: String, current: UInt16, maximum: UInt16)
    case brightnessOutOfRange(displayID: String, requested: UInt16, maximum: UInt16)
    case verificationFailed(displayID: String, requested: UInt16, actual: UInt16?)

    public var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, displayID, reason):
            let target = displayID.map { " for display \($0)" } ?? ""
            return "\(operation) failed\(target): \(reason)"
        case let .invalidBrightnessReply(displayID, current, maximum):
            return "Display \(displayID) returned invalid brightness values " +
                "(current \(current), maximum \(maximum))."
        case let .brightnessOutOfRange(displayID, requested, maximum):
            return "Brightness \(requested) is outside display \(displayID)'s " +
                "reported range 0…\(maximum)."
        case let .verificationFailed(displayID, requested, actual):
            let received = actual.map(String.init) ?? "no readable value"
            return "Display \(displayID) did not confirm brightness \(requested) " +
                "(received \(received))."
        }
    }
}

/// Serial, retrying access to VESA DDC/CI brightness (VCP feature 0x10).
///
/// DDC values are device-specific integer codes, not nits. The sync engine
/// converts them through the monitor's stored calibration curve.
public final class DDCTransport: @unchecked Sendable {
    public static let brightnessVCPCode: UInt8 = 0x10
    public enum LatencyMode: Sendable {
        case standard
        case lowLatency
    }

    private let operationLock = NSLock()
    private let maximumAttempts: Int
    private let retryDelay: TimeInterval
    private let verificationDelay: TimeInterval
    private let verificationReadAttempts: Int

    public init(
        maximumAttempts: Int = 3,
        retryDelay: TimeInterval = 0.04,
        verificationDelay: TimeInterval = 0.06,
        verificationReadAttempts: Int = 3
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.retryDelay = max(0, retryDelay)
        self.verificationDelay = max(0, verificationDelay)
        self.verificationReadAttempts = max(1, verificationReadAttempts)
    }

    public convenience init(mode: LatencyMode) {
        switch mode {
        case .standard:
            self.init()
        case .lowLatency:
            self.init(
                maximumAttempts: 2,
                retryDelay: 0.02,
                verificationDelay: 0.02,
                verificationReadAttempts: 1
            )
        }
    }

    public func discover() throws -> [DDCDisplay] {
        try serialized {
            var bridgeError: NSError?
            guard let services = CNDDCDiscoverExternalDisplays(&bridgeError) else {
                throw Self.operationError(
                    "External display discovery",
                    displayID: nil,
                    bridgeError: bridgeError
                )
            }
            return services.map(DDCDisplay.init(service:))
        }
    }

    public func readBrightness(
        _ display: DDCDisplay
    ) throws -> (current: UInt16, maximum: UInt16) {
        try serialized {
            try readBrightnessUnlocked(display, attempts: maximumAttempts)
        }
    }

    /// Sets raw VCP brightness. A zero `knownMaximum` is treated as unknown.
    /// With verification enabled (the default), a successful return means a
    /// valid readback exactly matched `value`.
    public func writeBrightness(
        _ display: DDCDisplay,
        value: UInt16,
        knownMaximum: UInt16? = nil,
        verify: Bool = true
    ) throws {
        try serialized {
            let maximum: UInt16
            if let knownMaximum, knownMaximum > 0 {
                maximum = knownMaximum
            } else {
                maximum = try readBrightnessUnlocked(
                    display,
                    attempts: maximumAttempts
                ).maximum
            }
            guard value <= maximum else {
                throw DDCTransportError.brightnessOutOfRange(
                    displayID: display.id,
                    requested: value,
                    maximum: maximum
                )
            }

            var lastReason = "The monitor did not accept the DDC write."
            var lastReadback: UInt16?

            for attempt in 1...maximumAttempts {
                var bridgeError: NSError?
                let wrote = CNDDCWriteVCP(
                    display.service,
                    Self.brightnessVCPCode,
                    value,
                    &bridgeError
                )

                if wrote {
                    guard verify else { return }
                    if verificationDelay > 0 {
                        Thread.sleep(forTimeInterval: verificationDelay)
                    }

                    var readback: (current: UInt16, maximum: UInt16)?
                    do {
                        readback = try readBrightnessUnlocked(
                            display,
                            attempts: verificationReadAttempts
                        )
                    } catch {
                        lastReason = error.localizedDescription
                    }

                    if let readback {
                        lastReadback = readback.current
                        guard value <= readback.maximum else {
                            throw DDCTransportError.brightnessOutOfRange(
                                displayID: display.id,
                                requested: value,
                                maximum: readback.maximum
                            )
                        }
                        if readback.current == value {
                            return
                        }
                        lastReason = "Readback was \(readback.current)."
                    }
                } else {
                    lastReason = bridgeError?.localizedDescription ??
                        "The monitor did not accept the DDC write."
                }

                if attempt < maximumAttempts, retryDelay > 0 {
                    Thread.sleep(forTimeInterval: retryDelay)
                }
            }

            if verify {
                throw DDCTransportError.verificationFailed(
                    displayID: display.id,
                    requested: value,
                    actual: lastReadback
                )
            }
            throw DDCTransportError.operationFailed(
                operation: "DDC brightness write",
                displayID: display.id,
                reason: lastReason
            )
        }
    }

    private func readBrightnessUnlocked(
        _ display: DDCDisplay,
        attempts: Int
    ) throws -> (current: UInt16, maximum: UInt16) {
        var lastReason = "The monitor returned no DDC brightness value."
        var lastInvalidReply: (current: UInt16, maximum: UInt16)?

        for attempt in 1...max(1, attempts) {
            var value = CNDDCVCPValue(current: 0, maximum: 0)
            var bridgeError: NSError?
            if CNDDCReadVCP(
                display.service,
                Self.brightnessVCPCode,
                &value,
                &bridgeError
            ) {
                if value.maximum > 0, value.current <= value.maximum {
                    return (current: value.current, maximum: value.maximum)
                }
                lastInvalidReply = (
                    current: value.current,
                    maximum: value.maximum
                )
                lastReason = "The monitor returned invalid brightness bounds."
            } else {
                lastReason = bridgeError?.localizedDescription ?? lastReason
            }

            if attempt < attempts, retryDelay > 0 {
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }

        if let lastInvalidReply {
            throw DDCTransportError.invalidBrightnessReply(
                displayID: display.id,
                current: lastInvalidReply.current,
                maximum: lastInvalidReply.maximum
            )
        }
        throw DDCTransportError.operationFailed(
            operation: "DDC brightness read",
            displayID: display.id,
            reason: lastReason
        )
    }

    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private static func operationError(
        _ operation: String,
        displayID: String?,
        bridgeError: NSError?
    ) -> DDCTransportError {
        .operationFailed(
            operation: operation,
            displayID: displayID,
            reason: bridgeError?.localizedDescription ?? "Unknown I/O error."
        )
    }
}
