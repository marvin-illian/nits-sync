import Dispatch
import CoreFoundation
import Foundation
import IOKit
import CoreGraphics
import Darwin
import ObjectiveC.runtime

/// Reads the luminance reported by the built-in Apple display.
///
/// This type only reads macOS display properties. It never changes the
/// built-in display's brightness, so macOS remains the source of truth when
/// automatic brightness is enabled.
public final class BuiltInNitsReader: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (_ nits: Double) -> Void

    /// Normal fallback polling cadence (10 Hz). This is used only when the
    /// private brightness-change notification interface is unavailable.
    public static let defaultPollingInterval: TimeInterval = 0.10

    /// Small changes below this value are not delivered to the callback.
    public static let defaultDeadbandNits = 0.5

    /// Low-latency fallback polling and filtering for the built-in source.
    public static let lowLatencyPollingInterval: TimeInterval = 0.05
    public static let lowLatencyDeadbandNits: Double = 0.2
    public static let lowLatencyNotificationSettleDelay: TimeInterval = 0.01

    /// Normal mode gives CoreBrightness more time to publish physical nits.
    public static let defaultNotificationSettleDelay: TimeInterval = 0.05

    /// macOS can post the notification before its physical-nits property has
    /// finished changing. One event-triggered follow-up avoids waiting for the
    /// watchdog without turning normal operation back into frequent polling.
    public static let notificationFollowUpDelay: TimeInterval = 0.12

    /// Notifications are the primary source. This infrequent timer catches a
    /// missed event after sleep or an internal macOS display-state transition.
    public static let notificationWatchdogInterval: TimeInterval = 1.0

    private let pollingInterval: TimeInterval
    private let deadbandNits: Double
    private let pollingQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let registryDisplayName: String?
    private let registryCapNits: Double?

    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pollingGeneration: UInt64 = 0
    private var notificationSequence: UInt64 = 0
    private var registeredDisplayID: CGDirectDisplayID?
    private var changeHandler: ChangeHandler?
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
        // Keep the hot path cheap. A valid CoreBrightness value, including
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

    /// Starts observing native brightness changes and samples immediately.
    ///
    /// When macOS's private notification interface is available, a one-second
    /// watchdog is the only recurring work. If registration is unavailable,
    /// this falls back to the configured polling cadence. The first available
    /// value is delivered; later values must cross `deadbandNits`. Calling this
    /// again replaces the previous observation.
    public func startPolling(onChange handler: @escaping ChangeHandler) {
        stopPolling()
        let source = DispatchSource.makeTimerSource(queue: pollingQueue)

        stateLock.lock()
        pollingGeneration &+= 1
        let generation = pollingGeneration
        timer = source
        changeHandler = handler
        registeredDisplayID = nil
        lastDeliveredNits = nil
        pendingCallbackNits = nil
        callbackScheduled = false
        stateLock.unlock()

        let observedDisplayID = registerForBrightnessChanges()
        stateLock.lock()
        let observationIsCurrent = generation == pollingGeneration && timer != nil
        if observationIsCurrent {
            registeredDisplayID = observedDisplayID
        }
        stateLock.unlock()

        if !observationIsCurrent, let observedDisplayID {
            unregisterForBrightnessChanges(displayID: observedDisplayID)
        }

        source.setEventHandler { [weak self] in
            self?.poll(generation: generation)
        }
        let repeatingInterval = observedDisplayID == nil
            ? pollingInterval
            : Self.notificationWatchdogInterval
        let timerLeeway: DispatchTimeInterval = observedDisplayID == nil
            ? .milliseconds(25)
            : .milliseconds(250)
        source.schedule(
            deadline: .now(),
            repeating: repeatingInterval,
            leeway: timerLeeway
        )
        // A source must be activated even if stopPolling() raced with setup and
        // cancelled it while it was suspended.
        source.activate()
    }

    /// Stops observing. Any callback already queued but not yet delivered is
    /// suppressed by the generation check.
    public func stopPolling() {
        stateLock.lock()
        pollingGeneration &+= 1
        notificationSequence &+= 1
        let previousTimer = timer
        let previousDisplayID = registeredDisplayID
        timer = nil
        registeredDisplayID = nil
        changeHandler = nil
        lastDeliveredNits = nil
        pendingCallbackNits = nil
        callbackScheduled = false
        stateLock.unlock()

        previousTimer?.cancel()
        if let previousDisplayID {
            unregisterForBrightnessChanges(displayID: previousDisplayID)
        }
    }

    private func poll(generation: UInt64) {
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
            self?.deliverPending(generation: generation)
        }
    }

    private func deliverPending(generation: UInt64) {
        stateLock.lock()
        guard generation == pollingGeneration, timer != nil else {
            stateLock.unlock()
            return
        }
        let nits = pendingCallbackNits
        let handler = changeHandler
        pendingCallbackNits = nil
        callbackScheduled = false
        stateLock.unlock()

        if let nits, let handler {
            handler(nits)
        }
    }
}

private extension BuiltInNitsReader {
    typealias RegisterBrightnessNotificationsFunction = @convention(c) (
        CGDirectDisplayID,
        CGDirectDisplayID,
        CFNotificationCallback
    ) -> Int32

    typealias UnregisterBrightnessNotificationsFunction = @convention(c) (
        CGDirectDisplayID,
        CGDirectDisplayID
    ) -> Int32

    final class WeakReaderBox {
        weak var reader: BuiltInNitsReader?

        init(_ reader: BuiltInNitsReader) {
            self.reader = reader
        }
    }

    static let notificationLock = NSLock()
    static var notificationReaders: [CGDirectDisplayID: WeakReaderBox] = [:]

    static let brightnessNotificationCallback: CFNotificationCallback = {
        _, observer, _, _, _ in
        guard let observer else { return }
        let rawDisplayID = UInt(bitPattern: observer)
        guard rawDisplayID <= UInt(UInt32.max) else { return }
        let displayID = CGDirectDisplayID(rawDisplayID)

        notificationLock.lock()
        let reader = notificationReaders[displayID]?.reader
        if reader == nil {
            notificationReaders.removeValue(forKey: displayID)
        }
        notificationLock.unlock()

        reader?.brightnessNotificationReceived(displayID: displayID)
    }

    func brightnessNotificationReceived(displayID: CGDirectDisplayID) {
        stateLock.lock()
        guard registeredDisplayID == displayID, timer != nil else {
            stateLock.unlock()
            return
        }
        let generation = pollingGeneration
        notificationSequence &+= 1
        let sequence = notificationSequence
        stateLock.unlock()

        // DisplayServices can publish before CoreBrightness's physical-nits
        // property has settled. Debounce rapid steps and read the latest value
        // after a short delay instead of replaying stale intermediate values.
        let settleDelay = pollingInterval <= Self.lowLatencyPollingInterval
            ? Self.lowLatencyNotificationSettleDelay
            : Self.defaultNotificationSettleDelay
        pollingQueue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            self?.pollAfterBrightnessNotification(
                generation: generation,
                sequence: sequence
            )
        }
        pollingQueue.asyncAfter(
            deadline: .now() + Self.notificationFollowUpDelay
        ) { [weak self] in
            self?.pollAfterBrightnessNotification(
                generation: generation,
                sequence: sequence
            )
        }
    }

    func pollAfterBrightnessNotification(
        generation: UInt64,
        sequence: UInt64
    ) {
        stateLock.lock()
        let isLatest = generation == pollingGeneration &&
            sequence == notificationSequence &&
            timer != nil
        stateLock.unlock()
        guard isLatest else { return }
        poll(generation: generation)
    }

    func registerForBrightnessChanges() -> CGDirectDisplayID? {
        guard let register = Self.registerBrightnessNotifications,
              Self.unregisterBrightnessNotifications != nil,
              let displayID = Self.activeBuiltInDisplayID() else {
            return nil
        }

        Self.notificationLock.lock()
        Self.notificationReaders[displayID] = WeakReaderBox(self)
        Self.notificationLock.unlock()

        let result = Self.performOnMain {
            register(
                displayID,
                displayID,
                Self.brightnessNotificationCallback
            )
        }
        guard result == KERN_SUCCESS else {
            Self.removeNotificationReader(self, displayID: displayID)
            return nil
        }
        return displayID
    }

    func unregisterForBrightnessChanges(displayID: CGDirectDisplayID) {
        Self.removeNotificationReader(self, displayID: displayID)
        Self.performOnMain {
            _ = Self.unregisterBrightnessNotifications?(displayID, displayID)
        }
    }

    static func performOnMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    static func removeNotificationReader(
        _ reader: BuiltInNitsReader,
        displayID: CGDirectDisplayID
    ) {
        notificationLock.lock()
        if notificationReaders[displayID]?.reader === reader {
            notificationReaders.removeValue(forKey: displayID)
        }
        notificationLock.unlock()
    }

    static let displayServicesHandle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices",
            RTLD_LAZY | RTLD_LOCAL
        )
    }()

    static let registerBrightnessNotifications: RegisterBrightnessNotificationsFunction? = {
        guard let displayServicesHandle,
              let symbol = dlsym(
                  displayServicesHandle,
                  "DisplayServicesRegisterForBrightnessChangeNotifications"
              ) else {
            return nil
        }
        return unsafeBitCast(
            symbol,
            to: RegisterBrightnessNotificationsFunction.self
        )
    }()

    static let unregisterBrightnessNotifications: UnregisterBrightnessNotificationsFunction? = {
        guard let displayServicesHandle,
              let symbol = dlsym(
                  displayServicesHandle,
                  "DisplayServicesUnregisterForBrightnessChangeNotifications"
              ) else {
            return nil
        }
        return unsafeBitCast(
            symbol,
            to: UnregisterBrightnessNotificationsFunction.self
        )
    }()

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
