import Dispatch
import Foundation
import IOKit
import CoreGraphics
import Darwin
import ObjectiveC.runtime

/// Reads the luminance reported by the built-in Apple display.
///
/// This type only reads I/O Registry properties. It never changes the built-in
/// display's brightness, so macOS remains the source of truth when automatic
/// brightness is enabled.
public final class BuiltInNitsReader: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (_ nits: Double) -> Void

    /// Normal polling cadence (10 Hz), good for smooth operation with little
    /// load while still following auto-brightness changes.
    public static let defaultPollingInterval: TimeInterval = 0.10

    /// Small changes below this value are not delivered to the callback.
    public static let defaultDeadbandNits = 0.5

    /// Low-latency polling and filtering for the built-in source. This keeps
    /// reaction time shorter while accepting a higher risk of jitter in noisy
    /// setups.
    public static let lowLatencyPollingInterval: TimeInterval = 0.05
    public static let lowLatencyDeadbandNits: Double = 0.2

    private let pollingInterval: TimeInterval
    private let deadbandNits: Double
    private let pollingQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let registryDisplayName: String?
    private let registryCapNits: Double?

    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pollingGeneration: UInt64 = 0
    private var lastDeliveredNits: Double?
    private var pendingCallbackNits: Double?
    private var callbackScheduled = false

    public init(
        pollingInterval: TimeInterval = BuiltInNitsReader.defaultPollingInterval,
        deadbandNits: Double = BuiltInNitsReader.defaultDeadbandNits,
            callbackQueue: DispatchQueue = .main
    ) {
        self.pollingInterval = max(0.05, pollingInterval)
        self.deadbandNits = max(0, deadbandNits)
        self.callbackQueue = callbackQueue
        let registrySnapshot = Self.readSnapshot()
        registryDisplayName = registrySnapshot.displayName
        registryCapNits = registrySnapshot.capNits
        pollingQueue = DispatchQueue(
            label: "app.nits-sync.builtin-nits-reader",
            qos: .utility
        )
    }

    deinit {
        stopPolling()
    }

    /// The current physical luminance of the built-in panel in cd/m² (nits).
    ///
    /// CoreBrightness's read-only `NitsPhysical` property is preferred because
    /// it is the effective live panel luminance, including automatic-brightness
    /// changes. Positive I/O Registry nits values are retained as fallbacks for
    /// OS revisions where that unheadered property is unavailable.
    public func currentNits() -> Double? {
        // Keep the 10 Hz path cheap. A valid CoreBrightness value, including
        // zero, is authoritative and does not require walking the I/O Registry.
        Self.coreBrightnessPhysicalNits() ?? Self.readSnapshot().currentNits
    }

    /// A human-readable name when the registry publishes one. Modern MacBook
    /// panels usually do not publish a model name, in which case a stable
    /// generic label is returned after the built-in panel is detected.
    public var builtInDisplayName: String? {
        registryDisplayName
    }

    /// The panel's reported hardware ceiling, if AppleARMBacklight publishes
    /// it. XDR displays can report their HDR peak here rather than the normal
    /// SDR ceiling, so callers should present this as capability metadata and
    /// must not use it to convert a brightness percentage to nits.
    public var builtInDisplayCapNits: Double? {
        registryCapNits
    }

    /// Starts sampling immediately and then every 100 ms by default.
    ///
    /// The first available value is delivered. Later values are delivered only
    /// after moving by at least `deadbandNits` from the last delivered value.
    /// The callback is dispatched on the queue supplied at initialization
    /// (the main queue by default). Calling this again replaces the old poller.
    public func startPolling(onChange handler: @escaping ChangeHandler) {
        let source = DispatchSource.makeTimerSource(queue: pollingQueue)

        stateLock.lock()
        pollingGeneration &+= 1
        let generation = pollingGeneration
        let previousTimer = timer
        timer = source
        lastDeliveredNits = nil
        pendingCallbackNits = nil
        callbackScheduled = false
        stateLock.unlock()

        previousTimer?.cancel()

        source.setEventHandler { [weak self] in
            self?.poll(generation: generation, handler: handler)
        }
        source.schedule(
            deadline: .now(),
            repeating: pollingInterval,
            leeway: .milliseconds(25)
        )
        // A source must be activated even if stopPolling() raced with setup and
        // cancelled it while it was suspended.
        source.activate()
    }

    /// Stops polling. Any callback already queued but not yet delivered is
    /// suppressed by the generation check.
    public func stopPolling() {
        stateLock.lock()
        pollingGeneration &+= 1
        let previousTimer = timer
        timer = nil
        lastDeliveredNits = nil
        pendingCallbackNits = nil
        callbackScheduled = false
        stateLock.unlock()

        previousTimer?.cancel()
    }

    private func poll(generation: UInt64, handler: @escaping ChangeHandler) {
        guard let nits = currentNits() else { return }

        stateLock.lock()
        let isCurrentPoller = generation == pollingGeneration && timer != nil
        let crossedDeadband = lastDeliveredNits.map {
            abs(nits - $0) >= deadbandNits
        } ?? true
        var shouldScheduleCallback = false
        if isCurrentPoller && crossedDeadband {
            lastDeliveredNits = nits
            pendingCallbackNits = nits
            if !callbackScheduled {
                callbackScheduled = true
                shouldScheduleCallback = true
            }
        }
        stateLock.unlock()

        guard shouldScheduleCallback else { return }

        callbackQueue.async { [weak self] in
            self?.deliverPending(generation: generation, handler: handler)
        }
    }

    private func deliverPending(
        generation: UInt64,
        handler: @escaping ChangeHandler
    ) {
        stateLock.lock()
        guard generation == pollingGeneration, timer != nil else {
            stateLock.unlock()
            return
        }
        let nits = pendingCallbackNits
        pendingCallbackNits = nil
        callbackScheduled = false
        stateLock.unlock()

        if let nits {
            handler(nits)
        }
    }
}

private extension BuiltInNitsReader {
    struct RegistrySnapshot {
        var framebufferNits: Double?
        var backlightNits: Double?
        var capNits: Double?
        var displayName: String?
        var foundBuiltInDisplay = false

        var currentNits: Double? {
            framebufferNits ?? backlightNits
        }
    }

    static func readSnapshot() -> RegistrySnapshot {
        var snapshot = RegistrySnapshot()

        if let framebuffer = copyFirstService(
            matching: "AppleCLCD2",
            where: isBuiltInFramebuffer
        ) {
            defer { IOObjectRelease(framebuffer) }
            snapshot.foundBuiltInDisplay = true

            if let rawLevel = numberProperty(
                of: framebuffer,
                named: "IOMFBBrightnessLevel"
            ) {
                snapshot.framebufferNits = validatedPositiveNits(
                    rawLevel.doubleValue / 65_536.0
                )
            }

            snapshot.displayName = publishedDisplayName(of: framebuffer)
        }

        if let backlight = copyFirstService(
            matching: "AppleARMBacklight",
            where: { _ in true }
        ) {
            defer { IOObjectRelease(backlight) }
            snapshot.foundBuiltInDisplay = true

            if let parameters = dictionaryProperty(
                of: backlight,
                named: "IODisplayParameters"
            ), let milliNits = parameters["BrightnessMilliNits"] as? [String: Any] {
                if let value = number(from: milliNits["value"]) {
                    snapshot.backlightNits = validatedPositiveNits(
                        value.doubleValue / 1_000.0
                    )
                }
                if let maximum = number(from: milliNits["max"]) {
                    snapshot.capNits = validatedPositiveNits(
                        maximum.doubleValue / 1_000.0
                    )
                }
            }
        }

        if snapshot.displayName == nil, snapshot.foundBuiltInDisplay {
            snapshot.displayName = "Built-in Display"
        }

        return snapshot
    }

    /// `disp0` is the integrated panel. External framebuffer nodes use names
    /// such as `dispext0`, including when connected through DisplayPort Alt
    /// Mode, and must never be mistaken for the luminance source.
    static func isBuiltInFramebuffer(_ service: io_service_t) -> Bool {
        if let matchedName = stringProperty(of: service, named: "IONameMatched") {
            if matchedName == "disp0" || matchedName.hasPrefix("disp0,") {
                return true
            }
            if matchedName.hasPrefix("dispext") {
                return false
            }
        }

        // Current Apple panels identify Apple as `00-10-fa` in this nested
        // dictionary. This is a conservative fallback for OS revisions that do
        // not publish IONameMatched on the framebuffer.
        if let attributes = dictionaryProperty(of: service, named: "DisplayAttributes"),
           let product = attributes["ProductAttributes"] as? [String: Any],
           let manufacturer = product["ManufacturerID"] as? String,
           manufacturer.caseInsensitiveCompare("00-10-fa") == .orderedSame {
            return true
        }

        return false
    }

    static func publishedDisplayName(of service: io_service_t) -> String? {
        if let attributes = dictionaryProperty(of: service, named: "DisplayAttributes"),
           let product = attributes["ProductAttributes"] as? [String: Any],
           let name = nonemptyString(product["ProductName"]) {
            return name
        }

        guard let property = property(of: service, named: "DisplayProductName") else {
            return nil
        }
        if let name = nonemptyString(property) {
            return name
        }
        if let localizedNames = property as? [String: Any] {
            for preferredKey in ["en_US", "en", "English"] {
                if let name = nonemptyString(localizedNames[preferredKey]) {
                    return name
                }
            }
            return localizedNames.values.compactMap(nonemptyString).first
        }
        return nil
    }

    static func validatedCurrentNits(_ value: Double) -> Double? {
        // The upper guard filters corrupt/sentinel registry values while still
        // allowing ample headroom above current XDR panel capabilities. Zero is
        // a real source value when the built-in backlight is fully off.
        guard value.isFinite, value >= 0, value <= 10_000 else { return nil }
        return value
    }

    static func validatedPositiveNits(_ value: Double) -> Double? {
        guard let value = validatedCurrentNits(value), value > 0 else { return nil }
        return value
    }

    /// CoreBrightness exposes this property through an Objective-C client but
    /// ships no public header. Resolve it dynamically so an OS change degrades
    /// to the I/O Registry fallbacks instead of preventing launch.
    static func coreBrightnessPhysicalNits() -> Double? {
        guard coreBrightnessHandle != nil,
              let displayID = activeBuiltInDisplayID(),
              let client = coreBrightnessClient,
              let messageSendPointer = dlsym(
                  UnsafeMutableRawPointer(bitPattern: -2),
                  "objc_msgSend"
              ) else {
            return nil
        }

        typealias CopyPropertyFunction = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            UInt64
        ) -> Unmanaged<AnyObject>?

        let copyProperty = unsafeBitCast(
            messageSendPointer,
            to: CopyPropertyFunction.self
        )
        let selector = NSSelectorFromString("copyPropertyForKey:andDisplay:")
        guard client.responds(to: selector),
              let object = copyProperty(
                  client,
                  selector,
                  "NitsPhysical" as NSString,
                  UInt64(displayID)
              )?.takeRetainedValue(),
              let number = object as? NSNumber else {
            return nil
        }
        return validatedCurrentNits(number.doubleValue)
    }

    static func activeBuiltInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return nil
        }
        return displays.prefix(Int(count)).first {
            CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0
        }
    }

    static let coreBrightnessHandle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/Versions/A/CoreBrightness",
            RTLD_LAZY | RTLD_LOCAL
        )
    }()

    /// Keep one client alive so polling reuses its backlightd connection.
    static let coreBrightnessClient: NSObject? = {
        guard coreBrightnessHandle != nil,
              let clientClass = NSClassFromString("DisplayServicesClient") as? NSObject.Type else {
            return nil
        }
        return clientClass.init()
    }()

    static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(from value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    static func numberProperty(
        of service: io_service_t,
        named name: String
    ) -> NSNumber? {
        property(of: service, named: name) as? NSNumber
    }

    static func stringProperty(
        of service: io_service_t,
        named name: String
    ) -> String? {
        property(of: service, named: name) as? String
    }

    static func dictionaryProperty(
        of service: io_service_t,
        named name: String
    ) -> [String: Any]? {
        property(of: service, named: name) as? [String: Any]
    }

    static func property(of service: io_service_t, named name: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            name as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    /// Returns a retained service. The caller owns one reference.
    static func copyFirstService(
        matching className: String,
        where predicate: (io_service_t) -> Bool
    ) -> io_service_t? {
        guard let matchingDictionary = IOServiceMatching(className) else {
            return nil
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matchingDictionary,
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { return nil }
            if predicate(service) {
                return service
            }
            IOObjectRelease(service)
        }
    }
}
