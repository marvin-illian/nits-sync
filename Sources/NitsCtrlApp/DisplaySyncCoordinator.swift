import Foundation
import NitsCtrlCore
import NitsCtrlHardware
import OSLog

enum CoordinatorPhase: Equatable {
    case starting
    case syncing
    case paused
    case calibrating(displayID: String)
    case quiescing
    case stopped
}

enum SystemPauseReason: Hashable, Sendable {
    case sleep
    case displaySleep
    case inactiveSession
    case powerOff

    var needsDelayedDisplayRecovery: Bool {
        self == .sleep || self == .displaySleep
    }

    var shouldRestoreBeforePause: Bool {
        // NSWorkspace posts screensDidSleep only after the display hardware is
        // already asleep, when a synchronous DDC restore may itself stall.
        self != .displaySleep
    }
}

struct ExternalDisplayStatus: Identifiable {
    let id: String
    let name: String
    let identity: ExternalDisplayIdentity
    let currentRawValue: UInt16?
    let maximumRawValue: UInt16?
    let estimatedNits: Double?
    let minimumNits: Double
    let maximumNits: Double
    let calibrationPointCount: Int
    let isEnabled: Bool
    let isReady: Bool
    let clamp: SyncClamp
    let error: String?
    let hasPendingRestore: Bool
    let isBlocked: Bool
}

struct CalibrationStatus {
    let displayID: String
    let displayName: String
    let identity: ExternalDisplayIdentity
    let points: [CalibrationPoint]
    let currentRawValue: UInt16?
    let maximumRawValue: UInt16?
    let isBlocked: Bool
}

struct SyncAppSnapshot {
    let phase: CoordinatorPhase
    let sourceName: String
    let sourceNits: Double?
    let syncEnabled: Bool
    let lowLatencySync: Bool
    let displays: [ExternalDisplayStatus]
    let calibration: CalibrationStatus?
    let message: String?
}

enum CoordinatorError: LocalizedError {
    case displayNotFound
    case invalidMaximum
    case calibrationNeedsThreePoints
    case calibrationUnavailable
    case unresolvedRestore
    case restoreFailed([String])

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "The display is no longer connected."
        case .invalidMaximum:
            return "Maximum luminance must be greater than the calibrated minimum."
        case .calibrationNeedsThreePoints:
            return "Record at least three different low, middle, and high matches first."
        case .calibrationUnavailable:
            return "Calibration is not active right now."
        case .unresolvedRestore:
            return "Restore this display's original brightness before calibrating it."
        case let .restoreFailed(names):
            return "Could not restore: \(names.joined(separator: ", ")). The recovery journal was kept."
        }
    }
}

/// Owns all DDC work on one serial queue. No producer can race a final restore.
final class DisplaySyncCoordinator: @unchecked Sendable {
    typealias StateHandler = @Sendable (SyncAppSnapshot) -> Void
    /// DCP display services can still be stale when the workspace first posts
    /// its wake notification. Give macOS a short window to rebuild them before
    /// performing synchronous DDC discovery and reads.
    private static let wakeRecoveryDelay: TimeInterval = 2
    /// Screen-parameter notifications arrive in bursts while macOS is still
    /// creating the new display's I/O services. Wait for the burst to settle
    /// before attempting DDC discovery.
    private static let displayConfigurationSettleDelay: TimeInterval = 0.75
    /// Live writes are intentionally not read back one-by-one. Waiting for a
    /// short quiet period lets slow DDC firmware finish the newest command and
    /// prevents rapid key presses from queueing stale verification work.
    private static let liveVerificationQuietPeriod: TimeInterval = 0.30

    private struct CalibrationSession {
        let displayID: String
        let displayName: String
        let identity: ExternalDisplayIdentity
        var points: [CalibrationPoint]
    }

    private let queue: DispatchQueue
    private var ddc: DDCTransport
    private var nitsReader: BuiltInNitsReader
    private let profiles: DisplayProfileRepository
    private let journalStore: RestoreJournalStore
    private let policy = SyncPolicy()
    private let sessionID = UUID()

    private var stateHandler: StateHandler?
    private var phase: CoordinatorPhase = .starting
    private var displays: [String: DDCDisplay] = [:]
    private var rawValues: [String: (current: UInt16, maximum: UInt16)] = [:]
    private var estimatedNits: [String: Double] = [:]
    private var clamps: [String: SyncClamp] = [:]
    private var displayErrors: [String: String] = [:]
    private var blockedDisplays = Set<String>()
    private var sessionEntries: [String: RestoreJournalEntry] = [:]
    private var sourceNits: Double?
    private var syncEnabled: Bool
    private var systemPauseReasons = Set<SystemPauseReason>()
    private var calibration: CalibrationSession?
    private var message: String?
    private var activity: NSObjectProtocol?
    private var lowLatencySync: Bool
    private var generation: UInt64 = 0
    private var displayRetrySchedule = MonotonicRetrySchedule()
    private var displayRetryDelay: TimeInterval = 2
    private var isRetryingDisplays = false
    private var displayConfigurationGeneration: UInt64 = 0
    private var writeRetryStates: [String: (rawValue: UInt16, attempts: Int)] = [:]
    private var wakeRecoveryWorkItem: DispatchWorkItem?
    private var needsWakeRecovery = false
    private var liveVerificationWorkItems: [String: DispatchWorkItem] = [:]
    private var liveVerificationTokens: [String: UInt64] = [:]
    private var liveVerificationSequence: UInt64 = 0
    private var lastLiveWriteUptime: [String: TimeInterval] = [:]
    private let logger = Logger(subsystem: "com.local.nits-sync", category: "coordinator")

    private var isSystemPaused: Bool {
        !systemPauseReasons.isEmpty
    }

    init(
        ddc: DDCTransport? = nil,
        profiles: DisplayProfileRepository = DisplayProfileRepository(
            fileURL: ApplicationSupport.existingProfilesURL
        ),
        journalStore: RestoreJournalStore = RestoreJournalStore(
            fileURL: ApplicationSupport.existingRestoreJournalURL
        )
    ) {
        let coordinatorQueue = DispatchQueue(
            label: "app.nits-sync.display-coordinator",
            qos: .userInitiated
        )
        queue = coordinatorQueue
        let lowLatencyEnabled = UserDefaults.standard.bool(
            forKey: Preferences.lowLatencySync
        )
        self.lowLatencySync = lowLatencyEnabled
        self.ddc = ddc ?? Self.makeDDCTransport(lowLatency: lowLatencyEnabled)
        self.profiles = profiles
        self.journalStore = journalStore
        nitsReader = Self.makeBuiltInNitsReader(
            lowLatency: lowLatencyEnabled,
            callbackQueue: coordinatorQueue
        )
        syncEnabled = UserDefaults.standard.bool(forKey: Preferences.syncEnabled)
    }

    func setLowLatencySyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Preferences.lowLatencySync)
        queue.async { [weak self] in
            guard let self else { return }
            guard self.lowLatencySync != enabled else { return }
            self.lowLatencySync = enabled
            let shouldResume: Bool
            switch self.phase {
            case .syncing, .calibrating:
                shouldResume = true
            default:
                shouldResume = false
            }
            if shouldResume {
                self.stopFollowingUnlocked()
            } else {
                self.nitsReader.stopPolling()
                self.cancelDisplayRetryUnlocked()
            }
            self.ddc = Self.makeDDCTransport(lowLatency: enabled)
            self.nitsReader = Self.makeBuiltInNitsReader(
                lowLatency: enabled,
                callbackQueue: self.queue
            )
            if shouldResume {
                if self.calibration != nil {
                    self.startCalibrationObservationUnlocked()
                } else if self.syncEnabled {
                    self.startFollowingUnlocked()
                }
            }
            self.publishUnlocked()
        }
    }

    private static func makeDDCTransport(lowLatency: Bool) -> DDCTransport {
        lowLatency ? DDCTransport(mode: .lowLatency) : DDCTransport(mode: .standard)
    }

    private static func makeBuiltInNitsReader(
        lowLatency: Bool,
        callbackQueue: DispatchQueue
    ) -> BuiltInNitsReader {
        if lowLatency {
            return BuiltInNitsReader(
                pollingInterval: BuiltInNitsReader.lowLatencyPollingInterval,
                deadbandNits: BuiltInNitsReader.lowLatencyDeadbandNits,
                callbackQueue: callbackQueue
            )
        }
        return BuiltInNitsReader(callbackQueue: callbackQueue)
    }

    func start(stateHandler: @escaping StateHandler) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateHandler = stateHandler
            self.phase = .starting
            self.refreshDisplaysUnlocked()
            if self.syncEnabled {
                self.startFollowingUnlocked()
            } else {
                self.phase = .paused
            }
            self.publishUnlocked()
        }
    }

    func refreshDisplays() {
        queue.async { [weak self] in
            guard let self,
                  !self.isSystemPaused,
                  self.wakeRecoveryWorkItem == nil,
                  self.phase != .quiescing,
                  self.phase != .stopped else {
                return
            }
            self.displayConfigurationGeneration &+= 1
            self.writeRetryStates.removeAll()
            self.cancelDisplayRetryUnlocked()
            self.refreshDisplaysUnlocked()
            if let sourceNits = self.sourceNits, self.phase == .syncing {
                self.applySourceNitsUnlocked(sourceNits)
            }
            self.publishUnlocked()
        }
    }

    /// Coalesces the burst of screen-parameter notifications generated by one
    /// physical connect or disconnect. Wake recovery remains the authority
    /// while a sleep transition is already in progress.
    func displayConfigurationChanged() {
        queue.async { [weak self] in
            guard let self,
                  !self.isSystemPaused,
                  self.wakeRecoveryWorkItem == nil,
                  self.phase != .quiescing,
                  self.phase != .stopped else { return }

            self.displayConfigurationGeneration &+= 1
            let activeGeneration = self.displayConfigurationGeneration
            self.queue.asyncAfter(
                deadline: .now() + Self.displayConfigurationSettleDelay
            ) { [weak self] in
                guard let self,
                      activeGeneration == self.displayConfigurationGeneration,
                      !self.isSystemPaused,
                      self.wakeRecoveryWorkItem == nil,
                      self.phase != .quiescing,
                      self.phase != .stopped else { return }

                self.logger.notice("Refreshing displays after a hardware configuration change")
                self.writeRetryStates.removeAll()
                self.cancelDisplayRetryUnlocked()
                self.refreshDisplaysUnlocked()
                if let sourceNits = self.sourceNits, self.phase == .syncing {
                    self.applySourceNitsUnlocked(sourceNits)
                }
                self.publishUnlocked()
            }
        }
    }

    func setSyncEnabled(_ enabled: Bool, completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(enabled, forKey: Preferences.syncEnabled)
            self.syncEnabled = enabled

            if enabled {
                if self.wakeRecoveryWorkItem != nil {
                    self.publishUnlocked()
                    Self.complete(completion, with: .success(()))
                    return
                }
                self.refreshDisplaysUnlocked()
                self.startFollowingUnlocked()
                self.publishUnlocked()
                Self.complete(completion, with: .success(()))
                return
            }

            self.stopFollowingUnlocked()
            self.phase = .paused
            self.writeRetryStates.removeAll()
            let failures = self.restoreCurrentSessionUnlocked()
            self.publishUnlocked()
            let result: Result<Void, Error> = failures.isEmpty
                ? .success(())
                : .failure(CoordinatorError.restoreFailed(failures))
            Self.complete(completion, with: result)
        }
    }

    func setDisplayEnabled(_ enabled: Bool, displayID: String) {
        queue.async { [weak self] in
            guard let self,
                  let display = self.displays[displayID],
                  var profile = self.profileUnlocked(for: display) else { return }
            // Treat an explicit off/on as a request to try immediately instead
            // of retaining any backoff state from an earlier transient error.
            self.writeRetryStates[displayID] = nil
            profile.isEnabled = enabled
            do {
                try self.profiles.upsert(profile)
                if !enabled {
                    _ = self.restoreCurrentSessionUnlocked(displayID: displayID)
                } else if let sourceNits = self.sourceNits, self.phase == .syncing {
                    self.applySourceNitsUnlocked(sourceNits, displayIDs: [displayID])
                }
            } catch {
                self.displayErrors[displayID] = error.localizedDescription
            }
            self.publishUnlocked()
        }
    }

    func setMaximumNits(_ maximumNits: Double, displayID: String) {
        queue.async { [weak self] in
            guard let self,
                  let display = self.displays[displayID],
                  var profile = self.profileUnlocked(for: display) else { return }
            let oldCurve = profile.calibration
            guard maximumNits.isFinite, maximumNits > oldCurve.minimumNits else {
                self.displayErrors[displayID] = CoordinatorError.invalidMaximum.localizedDescription
                self.publishUnlocked()
                return
            }

            let oldSpan = max(oldCurve.maximumNits - oldCurve.minimumNits, 0.001)
            let newSpan = maximumNits - oldCurve.minimumNits
            let scaledPoints = oldCurve.points.map { point in
                let fraction = (point.nits - oldCurve.minimumNits) / oldSpan
                return CalibrationPoint(
                    rawValue: point.rawValue,
                    nits: oldCurve.minimumNits + fraction * newSpan
                )
            }

            do {
                profile.calibration = try CalibrationCurve(points: scaledPoints)
                try self.profiles.upsert(profile)
                self.displayErrors[displayID] = nil
                if let sourceNits = self.sourceNits, self.phase == .syncing {
                    self.applySourceNitsUnlocked(sourceNits, displayIDs: [displayID])
                }
            } catch {
                self.displayErrors[displayID] = error.localizedDescription
            }
            self.publishUnlocked()
        }
    }

    func resetCalibration(displayID: String) {
        queue.async { [weak self] in
            guard let self,
                  let display = self.displays[displayID],
                  let raw = self.rawValues[displayID],
                  var profile = self.profileUnlocked(for: display) else { return }
            let detectedMaximum = EDIDLuminance.maximumNits(from: display.edidData)
                ?? profile.calibration.maximumNits
            do {
                profile.calibration = try CalibrationCurve.defaultCurve(
                    minimumNits: 30,
                    maximumNits: detectedMaximum,
                    rawMaximum: raw.maximum
                )
                try self.profiles.upsert(profile)
                self.displayErrors[displayID] = nil
                if let sourceNits = self.sourceNits, self.phase == .syncing {
                    self.applySourceNitsUnlocked(sourceNits, displayIDs: [displayID])
                }
            } catch {
                self.displayErrors[displayID] = error.localizedDescription
            }
            self.publishUnlocked()
        }
    }

    func beginCalibration(displayID: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isSystemPaused,
                  self.calibration == nil,
                  (self.phase == .syncing || self.phase == .paused) else {
                Self.complete(completion, with: .failure(CoordinatorError.calibrationUnavailable))
                return
            }
            guard let display = self.displays[displayID] else {
                Self.complete(completion, with: .failure(CoordinatorError.displayNotFound))
                return
            }
            guard !self.blockedDisplays.contains(displayID) else {
                Self.complete(completion, with: .failure(CoordinatorError.unresolvedRestore))
                return
            }
            self.stopFollowingUnlocked()
            let failures = self.restoreCurrentSessionUnlocked()
            guard failures.isEmpty else {
                self.resumeFollowingIfAppropriateUnlocked()
                self.publishUnlocked()
                Self.complete(completion, with: .failure(CoordinatorError.restoreFailed(failures)))
                return
            }
            self.calibration = CalibrationSession(
                displayID: displayID,
                displayName: display.name,
                identity: display.identity,
                points: []
            )
            self.phase = .calibrating(displayID: displayID)
            self.message = "Set the Mac brightness, use the External Brightness slider to match the white reference, then record the match."
            self.startCalibrationObservationUnlocked()
            self.publishUnlocked()
            Self.complete(completion, with: .success(()))
        }
    }

    func recordCalibrationPoint(completion: ((Result<CalibrationPoint, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .calibrating = self.phase else {
                Self.complete(completion, with: .failure(CoordinatorError.calibrationUnavailable))
                return
            }
            guard
                  var calibration = self.calibration,
                  let display = self.displays[calibration.displayID],
                  let nits = self.nitsReader.currentNits() else {
                Self.complete(completion, with: .failure(CoordinatorError.displayNotFound))
                return
            }
            guard !self.blockedDisplays.contains(display.id) else {
                Self.complete(completion, with: .failure(CoordinatorError.unresolvedRestore))
                return
            }
            do {
                let raw = try self.ddc.readBrightness(display)
                let point = CalibrationPoint(rawValue: raw.current, nits: nits)
                calibration.points.removeAll {
                    $0.rawValue == point.rawValue || abs($0.nits - point.nits) < 0.5
                }
                calibration.points.append(point)
                calibration.points.sort { $0.rawValue < $1.rawValue }
                self.calibration = calibration
                self.rawValues[display.id] = raw
                self.message = "Recorded \(Int(nits.rounded())) nits at monitor value \(raw.current)."
                self.publishUnlocked()
                Self.complete(completion, with: .success(point))
            } catch {
                self.displayErrors[display.id] = error.localizedDescription
                self.publishUnlocked()
                Self.complete(completion, with: .failure(error))
            }
        }
    }

    func setCalibrationBrightness(
        _ rawValue: UInt16,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .calibrating = self.phase else {
                Self.complete(completion, with: .failure(CoordinatorError.calibrationUnavailable))
                return
            }
            guard
                  let calibration = self.calibration,
                  let display = self.displays[calibration.displayID],
                  let raw = self.rawValues[display.id] else {
                Self.complete(completion, with: .failure(CoordinatorError.displayNotFound))
                return
            }
            guard !self.blockedDisplays.contains(display.id) else {
                Self.complete(completion, with: .failure(CoordinatorError.unresolvedRestore))
                return
            }

            let target = min(rawValue, raw.maximum)
            guard target != raw.current else {
                Self.complete(completion, with: .success(()))
                return
            }

            do {
                let baseline = try self.captureBaselineIfNeededUnlocked(for: display)
                do {
                    var intended = baseline
                    intended.recordWriteIntent(target)
                    _ = try self.journalStore.upsert(intended)
                    self.sessionEntries[display.id] = intended

                    try self.ddc.writeBrightness(
                        display,
                        value: target,
                        knownMaximum: baseline.originalMaximumRawValue,
                        verify: true
                    )
                    self.rawValues[display.id] = (
                        current: target,
                        maximum: baseline.originalMaximumRawValue
                    )

                    var updated = intended
                    updated.confirmWrite(target)
                    _ = try self.journalStore.upsert(updated)
                    self.sessionEntries[display.id] = updated
                    self.displayErrors[display.id] = nil
                } catch let writeError {
                    var pending = self.sessionEntries[display.id] ?? baseline
                    pending.markRestorePending()
                    _ = try? self.journalStore.upsert(pending)
                    self.sessionEntries[display.id] = pending
                    do {
                        try self.restoreEntryUnlocked(pending, display: display)
                        self.sessionEntries[display.id] = nil
                        self.rawValues[display.id] = (
                            current: pending.originalRawValue,
                            maximum: pending.originalMaximumRawValue
                        )
                    } catch let restoreError {
                        self.blockedDisplays.insert(display.id)
                        throw CoordinatorError.restoreFailed([
                            "\(display.name) (\(restoreError.localizedDescription))",
                        ])
                    }
                    throw writeError
                }

                self.updateActivityUnlocked()
                self.publishUnlocked()
                Self.complete(completion, with: .success(()))
            } catch {
                self.displayErrors[display.id] = error.localizedDescription
                self.updateActivityUnlocked()
                self.publishUnlocked()
                Self.complete(completion, with: .failure(error))
            }
        }
    }

    func finishCalibration(completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .calibrating = self.phase else {
                Self.complete(completion, with: .failure(CoordinatorError.calibrationUnavailable))
                return
            }
            guard
                  let calibration = self.calibration,
                  let display = self.displays[calibration.displayID],
                  var profile = self.profileUnlocked(for: display) else {
                Self.complete(completion, with: .failure(CoordinatorError.displayNotFound))
                return
            }
            guard !self.blockedDisplays.contains(display.id) else {
                Self.complete(completion, with: .failure(CoordinatorError.unresolvedRestore))
                return
            }
            guard calibration.points.count >= 3 else {
                Self.complete(completion, with: .failure(CoordinatorError.calibrationNeedsThreePoints))
                return
            }
            do {
                profile.calibration = try CalibrationCurve(points: calibration.points)
                try self.profiles.upsert(profile)
                if self.syncEnabled, !self.isSystemPaused {
                    self.calibration = nil
                    self.message = "Calibration saved for \(display.name)."
                    self.startFollowingUnlocked()
                } else {
                    let failures = self.restoreCurrentSessionUnlocked()
                    guard failures.isEmpty else {
                        Self.complete(
                            completion,
                            with: .failure(CoordinatorError.restoreFailed(failures))
                        )
                        return
                    }
                    self.calibration = nil
                    self.stopFollowingUnlocked()
                    self.message = "Calibration saved for \(display.name)."
                    self.phase = .paused
                }
                self.publishUnlocked()
                Self.complete(completion, with: .success(()))
            } catch {
                Self.complete(completion, with: .failure(error))
            }
        }
    }

    func cancelCalibration(completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .calibrating = self.phase else {
                Self.complete(completion, with: .failure(CoordinatorError.calibrationUnavailable))
                return
            }
            let failures = self.restoreCurrentSessionUnlocked()
            guard failures.isEmpty else {
                self.message = CoordinatorError.restoreFailed(failures).localizedDescription
                self.publishUnlocked()
                Self.complete(
                    completion,
                    with: .failure(CoordinatorError.restoreFailed(failures))
                )
                return
            }
            self.calibration = nil
            self.message = nil
            if self.syncEnabled, !self.isSystemPaused {
                self.startFollowingUnlocked()
            } else {
                self.stopFollowingUnlocked()
                self.phase = .paused
            }
            self.publishUnlocked()
            Self.complete(completion, with: .success(()))
        }
    }

    func pauseForSystemEvent(_ reason: SystemPauseReason) {
        queue.async { [weak self] in
            guard let self, self.phase != .quiescing, self.phase != .stopped else {
                return
            }
            let wasPaused = self.isSystemPaused
            self.systemPauseReasons.insert(reason)
            if reason.needsDelayedDisplayRecovery {
                self.needsWakeRecovery = true
            }
            self.cancelWakeRecoveryUnlocked()
            self.logger.notice("Pausing display sync for system event: \(String(describing: reason), privacy: .public)")
            guard !wasPaused else { return }
            self.stopFollowingUnlocked()
            self.phase = .paused
            if reason.shouldRestoreBeforePause {
                _ = self.restoreCurrentSessionUnlocked()
            }
            self.publishUnlocked()
        }
    }

    func resumeAfterSystemEvent(_ reason: SystemPauseReason) {
        queue.async { [weak self] in
            guard let self, self.phase != .quiescing, self.phase != .stopped else {
                return
            }
            guard self.systemPauseReasons.remove(reason) != nil,
                  !self.isSystemPaused else { return }
            self.logger.notice("Resuming display sync after system event: \(String(describing: reason), privacy: .public)")
            if self.needsWakeRecovery {
                self.needsWakeRecovery = false
                self.scheduleWakeRecoveryUnlocked()
            } else {
                self.refreshDisplaysUnlocked()
                self.resumeFollowingIfAppropriateUnlocked()
            }
            self.publishUnlocked()
        }
    }

    func resumeAfterCancelledShutdown() {
        NotificationCenter.default.post(
            name: .nitsCtrlCoordinatorDidResumeAfterCancelledShutdown,
            object: self
        )
        queue.async { [weak self] in
            guard let self else { return }
            self.phase = .paused
            self.refreshDisplaysUnlocked()
            self.resumeFollowingIfAppropriateUnlocked()
            self.publishUnlocked()
        }
    }

    func shutdown(completion: @escaping (Result<Void, Error>) -> Void) {
        NotificationCenter.default.post(
            name: .nitsCtrlCoordinatorWillShutdown,
            object: self
        )
        queue.async { [weak self] in
            guard let self else {
                Self.complete(completion, with: .success(()))
                return
            }
            if self.phase == .stopped {
                let failures = Self.uniqueNames(self.pendingRestoreNamesUnlocked())
                if failures.isEmpty {
                    Self.complete(completion, with: .success(()))
                } else {
                    self.phase = .paused
                    self.publishUnlocked()
                    Self.complete(
                        completion,
                        with: .failure(CoordinatorError.restoreFailed(failures))
                    )
                }
                return
            }
            self.phase = .quiescing
            self.stopFollowingUnlocked()
            self.publishUnlocked()
            // Rediscover first so Retry can see a monitor that was reconnected.
            // Discovery also attempts recovery of journals from older sessions.
            self.refreshDisplaysUnlocked()
            var failures = self.restoreCurrentSessionUnlocked()
            // A current-session restore can make an older interrupted-session
            // entry safe to recover, so try old entries once more afterward.
            self.recoverInterruptedSessionsUnlocked()
            failures.append(contentsOf: self.pendingRestoreNamesUnlocked())
            failures = Self.uniqueNames(failures)
            self.phase = failures.isEmpty ? .stopped : .paused
            self.publishUnlocked()
            let result: Result<Void, Error> = failures.isEmpty
                ? .success(())
                : .failure(CoordinatorError.restoreFailed(failures))
            Self.complete(completion, with: result)
        }
    }

    private func startFollowingUnlocked() {
        guard !isSystemPaused, calibration == nil, phase != .quiescing, phase != .stopped else {
            return
        }
        generation &+= 1
        let activeGeneration = generation
        phase = .syncing
        if displays.isEmpty || displays.values.contains(where: {
            rawValues[$0.id] == nil || profileUnlocked(for: $0) == nil
        }) {
            scheduleDisplayRetryUnlocked()
        }
        nitsReader.startPolling { [weak self] nits in
            guard let self,
                  activeGeneration == self.generation,
                  self.phase == .syncing else {
                return
            }
            if self.shouldApplySourceNitsUnlocked(nits) {
                self.applySourceNitsUnlocked(nits)
                self.publishUnlocked()
            } else if self.isRetryingDisplays {
                // A liveness heartbeat also replaces a retry callback whose
                // deadline passed without execution during a display switch.
                self.reconcileDisplayRetryUnlocked()
            }
        }
    }

    /// Calibration follows the built-in panel read-only. External writes only
    /// happen when the user releases the calibration slider.
    private func startCalibrationObservationUnlocked() {
        guard !isSystemPaused,
              let calibration,
              phase != .quiescing,
              phase != .stopped else { return }
        generation &+= 1
        let activeGeneration = generation
        phase = .calibrating(displayID: calibration.displayID)
        if displays[calibration.displayID] == nil ||
            rawValues[calibration.displayID] == nil {
            _ = scheduleDisplayRetryUnlocked()
        }
        nitsReader.startPolling { [weak self] nits in
            guard let self,
                  activeGeneration == self.generation,
                  self.calibration != nil,
                  case .calibrating = self.phase,
                  self.shouldApplySourceNitsUnlocked(nits) else { return }
            self.sourceNits = nits
            self.publishUnlocked()
        }
    }

    private func stopFollowingUnlocked() {
        generation &+= 1
        displayConfigurationGeneration &+= 1
        nitsReader.stopPolling()
        cancelDisplayRetryUnlocked()
        cancelAllLiveVerificationsUnlocked()
        cancelWakeRecoveryUnlocked()
    }

    private func resumeFollowingIfAppropriateUnlocked() {
        if calibration != nil, !isSystemPaused {
            startCalibrationObservationUnlocked()
        } else if syncEnabled, !isSystemPaused {
            startFollowingUnlocked()
        } else {
            phase = .paused
        }
    }

    private func scheduleWakeRecoveryUnlocked() {
        cancelWakeRecoveryUnlocked()
        phase = .paused
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeRecoveryWorkItem = nil
            guard !self.isSystemPaused,
                  self.phase != .quiescing,
                  self.phase != .stopped else { return }
            self.logger.notice("Starting delayed display rediscovery after wake")
            self.refreshDisplaysUnlocked()
            self.resumeFollowingIfAppropriateUnlocked()
            self.reapplyCurrentSourceAfterWakeUnlocked()
            self.publishUnlocked()
        }
        wakeRecoveryWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + Self.wakeRecoveryDelay,
            execute: workItem
        )
    }

    private func cancelWakeRecoveryUnlocked() {
        wakeRecoveryWorkItem?.cancel()
        wakeRecoveryWorkItem = nil
    }

    /// A wake can race the first source callback: the reader may sample while
    /// the coordinator is still switching generations, making that callback
    /// correctly stale. Do not wait for another user brightness change. Apply
    /// a fresh source sample immediately, or the last valid sample while the
    /// built-in panel is temporarily unavailable in clamshell transitions.
    private func reapplyCurrentSourceAfterWakeUnlocked() {
        guard phase == .syncing else { return }
        let currentSourceNits = nitsReader.currentNits()
        guard let recoveredSourceNits = currentSourceNits ?? sourceNits,
              recoveredSourceNits.isFinite,
              recoveredSourceNits >= 0 else {
            logger.notice("No valid built-in luminance is available after wake; waiting for the source watchdog")
            return
        }

        if currentSourceNits == nil {
            logger.notice("Reapplying cached source luminance after wake: \(recoveredSourceNits, format: .fixed(precision: 2)) nits")
        } else {
            logger.notice("Reapplying current source luminance after wake: \(recoveredSourceNits, format: .fixed(precision: 2)) nits")
        }
        applySourceNitsUnlocked(recoveredSourceNits)
    }

    /// The hardware reader emits a periodic liveness heartbeat in notification
    /// mode. Only a value the coordinator has not already accepted should run
    /// policy application and UI publication; this keeps the heartbeat cheap
    /// while allowing it to recover a callback dropped during a generation
    /// transition.
    private func shouldApplySourceNitsUnlocked(_ nits: Double) -> Bool {
        guard nits.isFinite, nits >= 0 else { return false }
        let deadband = lowLatencySync
            ? BuiltInNitsReader.lowLatencyDeadbandNits
            : BuiltInNitsReader.defaultDeadbandNits
        return sourceNits.map { abs(nits - $0) >= deadband } ?? true
    }

    private func refreshDisplaysUnlocked() {
        let wasRetrying = isRetryingDisplays
        let previousDisplayIDs = Set(displays.keys)
        let discoveryStarted = ProcessInfo.processInfo.systemUptime
        do {
            let found = try ddc.discover()
            let discoveryDuration = ProcessInfo.processInfo.systemUptime - discoveryStarted
            if discoveryDuration >= 1 {
                logger.notice("External display discovery took \(discoveryDuration, format: .fixed(precision: 2)) seconds")
            }
            displays = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            if Set(displays.keys) != previousDisplayIDs {
                let names = found.map(\.name).sorted().joined(separator: ", ")
                let summary = names.isEmpty ? "none" : names
                logger.notice("External display set changed: \(summary, privacy: .public)")
            }
            rawValues = rawValues.filter { displays[$0.key] != nil }
            estimatedNits = estimatedNits.filter { displays[$0.key] != nil }
            clamps = clamps.filter { displays[$0.key] != nil }
            writeRetryStates = writeRetryStates.filter { displays[$0.key] != nil }
            lastLiveWriteUptime = lastLiveWriteUptime.filter { displays[$0.key] != nil }
            let disconnectedVerificationIDs = liveVerificationWorkItems.keys.filter {
                displays[$0] == nil
            }
            for displayID in disconnectedVerificationIDs {
                cancelLiveVerificationUnlocked(displayID: displayID)
            }

            var needsRetry = found.isEmpty || (calibration.map {
                displays[$0.displayID] == nil
            } ?? false)
            for display in found {
                let readStarted = ProcessInfo.processInfo.systemUptime
                do {
                    let raw = try ddc.readBrightness(display)
                    let readDuration = ProcessInfo.processInfo.systemUptime - readStarted
                    if readDuration >= 1 {
                        logger.notice("DDC brightness read for \(display.name, privacy: .public) took \(readDuration, format: .fixed(precision: 2)) seconds")
                    }
                    rawValues[display.id] = raw
                    if profiles.profile(for: display.identity) == nil {
                        let maxNits = EDIDLuminance.maximumNits(from: display.edidData) ?? 350
                        let curve = try CalibrationCurve.defaultCurve(
                            minimumNits: 30,
                            maximumNits: maxNits,
                            rawMaximum: raw.maximum
                        )
                        try profiles.upsert(DisplayProfile(
                            identity: display.identity,
                            name: display.name,
                            calibration: curve
                        ))
                    }
                    if writeRetryStates[display.id] == nil {
                        displayErrors[display.id] = nil
                    }
                } catch {
                    let readDuration = ProcessInfo.processInfo.systemUptime - readStarted
                    logger.notice("DDC brightness read failed for \(display.name, privacy: .public) after \(readDuration, format: .fixed(precision: 2)) seconds: \(error.localizedDescription, privacy: .public)")
                    rawValues[display.id] = nil
                    displayErrors[display.id] = error.localizedDescription
                    needsRetry = true
                }
            }
            // Keep discovery and crash recovery inseparable. This prevents a
            // newly connected display from being mutated before an older
            // session's durable baseline has been considered.
            recoverInterruptedSessionsUnlocked()
            _ = restoreCurrentSessionUnlocked(pendingOnly: true)
            let hasConnectedPendingRestore = sessionEntries.values.contains {
                $0.state == .restorePending && displays[$0.identity.stableKey] != nil
            }
            needsRetry = needsRetry || hasConnectedPendingRestore
            if needsRetry {
                _ = scheduleDisplayRetryUnlocked()
            } else if wasRetrying {
                message = nil
            }
        } catch {
            let discoveryDuration = ProcessInfo.processInfo.systemUptime - discoveryStarted
            logger.notice("External display discovery failed after \(discoveryDuration, format: .fixed(precision: 2)) seconds: \(error.localizedDescription, privacy: .public)")
            let scheduled = scheduleDisplayRetryUnlocked()
            message = error.localizedDescription +
                (scheduled ? " Retrying automatically." : "")
        }
    }

    @discardableResult
    private func scheduleDisplayRetryUnlocked() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if displayRetrySchedule.hasPendingRetry(at: now) {
            isRetryingDisplays = true
            return true
        }
        guard canRetryDisplaysUnlocked else {
            isRetryingDisplays = false
            return false
        }

        isRetryingDisplays = true
        let scheduledDelay = displayRetryDelay
        guard let reservation = displayRetrySchedule.reserve(
            after: scheduledDelay,
            now: now
        ) else { return true }
        logger.notice("Scheduling display recovery in \(scheduledDelay, format: .fixed(precision: 1)) seconds")
        queue.asyncAfter(deadline: .now() + scheduledDelay) { [weak self] in
            guard let self else { return }
            guard self.displayRetrySchedule.consume(reservation) else { return }
            guard self.canRetryDisplaysUnlocked else {
                self.isRetryingDisplays = false
                return
            }

            self.refreshDisplaysUnlocked()
            if let sourceNits = self.sourceNits, self.phase == .syncing {
                self.applySourceNitsUnlocked(sourceNits)
            }
            self.reconcileDisplayRetryUnlocked()
            self.publishUnlocked()
        }
        displayRetryDelay = min(displayRetryDelay * 2, 15)
        return true
    }

    private func reconcileDisplayRetryUnlocked() {
        guard canRetryDisplaysUnlocked else {
            cancelDisplayRetryUnlocked()
            return
        }

        let lacksReadyDisplay = displays.isEmpty || displays.values.contains {
            rawValues[$0.id] == nil || profileUnlocked(for: $0) == nil
        }
        let hasPendingWrite = phase == .syncing && writeRetryStates.contains {
            displayID, _ in
            guard let display = displays[displayID],
                  !blockedDisplays.contains(displayID) else { return false }
            return profileUnlocked(for: display)?.isEnabled == true
        }
        let hasConnectedPendingRestore = sessionEntries.values.contains {
            $0.state == .restorePending && displays[$0.identity.stableKey] != nil
        }
        let calibrationDisplayIsMissing = calibration.map {
            displays[$0.displayID] == nil || rawValues[$0.displayID] == nil
        } ?? false

        if lacksReadyDisplay || hasPendingWrite || hasConnectedPendingRestore ||
            calibrationDisplayIsMissing {
            _ = scheduleDisplayRetryUnlocked()
        } else {
            cancelDisplayRetryUnlocked()
        }
    }

    private var canRetryDisplaysUnlocked: Bool {
        guard !isSystemPaused,
              phase != .quiescing,
              phase != .stopped else { return false }
        if calibration != nil {
            if case .calibrating = phase { return true }
            return false
        }
        return syncEnabled
    }

    private func cancelDisplayRetryUnlocked() {
        displayRetrySchedule.cancel()
        displayRetryDelay = 2
        let automaticSuffix = " Retrying automatically."
        if let message, message.hasSuffix(automaticSuffix) {
            self.message = String(message.dropLast(automaticSuffix.count))
        }
        let retrySuffix = " Retrying automatically."
        for (displayID, error) in displayErrors.filter({
            $0.value.hasSuffix(retrySuffix)
        }) {
            displayErrors[displayID] = String(error.dropLast(retrySuffix.count)) +
                " Choose Refresh Displays to try again."
        }
        isRetryingDisplays = false
    }

    private func recoverInterruptedSessionsUnlocked() {
        guard let journal = try? journalStore.load() else { return }
        let oldEntries = journal.entries.filter { $0.sessionID != sessionID }
        guard !oldEntries.isEmpty else { return }

        for entry in oldEntries {
            let matchingDisplays = displays.values.filter {
                $0.identity.matchesForPersistence(entry.identity)
            }
            guard matchingDisplays.count == 1,
                  let display = matchingDisplays.first else {
                // Never guess when a legacy identity can describe more than
                // one connected panel. Leave the durable journal untouched.
                for candidate in matchingDisplays {
                    blockedDisplays.insert(candidate.id)
                    displayErrors[candidate.id] = "A previous brightness restore is pending, but its saved monitor identity matches multiple displays."
                }
                continue
            }
            let key = display.id
            guard !entry.identity.isAmbiguous else {
                blockedDisplays.insert(key)
                displayErrors[key] = "A previous brightness restore is pending, but this monitor's identity is ambiguous."
                continue
            }
            do {
                let current = try ddc.readBrightness(display)
                if current.current == entry.originalRawValue {
                    _ = try journalStore.removeEntry(
                        for: entry.identity,
                        sessionID: entry.sessionID
                    )
                    rawValues[key] = current
                    blockedDisplays.remove(key)
                    displayErrors[key] = nil
                } else if entry.knownAppWrittenRawValues.contains(current.current) {
                    try ddc.writeBrightness(
                        display,
                        value: entry.originalRawValue,
                        knownMaximum: current.maximum,
                        verify: true
                    )
                    _ = try journalStore.removeEntry(
                        for: entry.identity,
                        sessionID: entry.sessionID
                    )
                    rawValues[key] = (
                        current: entry.originalRawValue,
                        maximum: current.maximum
                    )
                    blockedDisplays.remove(key)
                    displayErrors[key] = nil
                    message = "Recovered \(display.name)'s brightness after an interrupted session."
                } else {
                    blockedDisplays.insert(key)
                    displayErrors[key] = "A previous restore is pending, but the monitor was changed afterward. Sync is paused for it to protect that newer setting."
                }
            } catch {
                blockedDisplays.insert(key)
                displayErrors[key] = "Pending restore: \(error.localizedDescription)"
            }
        }
        updateActivityUnlocked()
    }

    private func applySourceNitsUnlocked(
        _ nits: Double,
        displayIDs: Set<String>? = nil
    ) {
        guard nits.isFinite, nits >= 0, phase == .syncing else { return }
        sourceNits = nits

        for display in displays.values.sorted(by: { $0.id < $1.id }) {
            if let displayIDs, !displayIDs.contains(display.id) { continue }
            guard !blockedDisplays.contains(display.id),
                  rawValues[display.id] != nil,
                  let profile = profileUnlocked(for: display),
                  let target = policy.target(for: nits, profile: profile) else {
                continue
            }
            estimatedNits[display.id] = target.estimatedNits
            clamps[display.id] = target.clamp
            if writeRetryStates[display.id]?.rawValue != target.rawValue {
                writeRetryStates[display.id] = nil
            }
            if writeRetryStates[display.id] != nil,
               displayRetrySchedule.hasPendingRetry(
                   at: ProcessInfo.processInfo.systemUptime
               ) {
                continue
            }
            if rawValues[display.id]?.current == target.rawValue {
                writeRetryStates[display.id] = nil
                displayErrors[display.id] = nil
                if sessionEntries[display.id]?.pendingRawValue == target.rawValue,
                   liveVerificationWorkItems[display.id] == nil {
                    scheduleLiveVerificationUnlocked(
                        displayID: display.id,
                        targetRawValue: target.rawValue,
                        didReapply: false
                    )
                }
                continue
            }
            do {
                let baseline = try captureBaselineIfNeededUnlocked(for: display)
                do {
                    // Record intent before touching hardware. Recovery retains
                    // the bounded set of recent values that may have reached
                    // slow monitor firmware during this unverified burst.
                    var intended = baseline
                    intended.recordWriteIntent(target.rawValue)
                    _ = try journalStore.upsert(intended)
                    sessionEntries[display.id] = intended

                    cancelLiveVerificationUnlocked(displayID: display.id)
                    try ddc.writeBrightness(
                        display,
                        value: target.rawValue,
                        knownMaximum: baseline.originalMaximumRawValue,
                        verify: false
                    )
                    rawValues[display.id] = (
                        current: target.rawValue,
                        maximum: baseline.originalMaximumRawValue
                    )
                    lastLiveWriteUptime[display.id] = ProcessInfo.processInfo.systemUptime
                    writeRetryStates[display.id] = nil
                    displayErrors[display.id] = nil
                    scheduleLiveVerificationUnlocked(
                        displayID: display.id,
                        targetRawValue: target.rawValue,
                        didReapply: false
                    )
                    logger.debug("Sent live sync target to \(display.name, privacy: .public): \(target.rawValue, privacy: .public)/\(baseline.originalMaximumRawValue, privacy: .public)")
                } catch let syncError {
                    // Keep the baseline entry and retry this write instead of
                    // immediately restoring while a transient write failure is
                    // being resolved.
                    var pending = sessionEntries[display.id] ?? baseline
                    pending.recordWriteIntent(target.rawValue)
                    _ = try? journalStore.upsert(pending)
                    sessionEntries[display.id] = pending
                    logger.notice("Live sync SET failed for \(display.name, privacy: .public), target \(target.rawValue, privacy: .public): \(syncError.localizedDescription, privacy: .public)")
                    recordRetryableWriteFailureUnlocked(
                        syncError,
                        displayID: display.id,
                        targetRawValue: target.rawValue
                    )
                }
            } catch {
                logger.notice("Could not prepare live sync for \(display.name, privacy: .public), target \(target.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                recordRetryableWriteFailureUnlocked(
                    error,
                    displayID: display.id,
                    targetRawValue: target.rawValue
                )
            }
        }
        updateActivityUnlocked()
        reconcileDisplayRetryUnlocked()
    }

    /// Verifies only the newest live target after DDC traffic has gone quiet.
    /// Calibration and restoration continue to use synchronous verification.
    private func scheduleLiveVerificationUnlocked(
        displayID: String,
        targetRawValue: UInt16,
        didReapply: Bool
    ) {
        cancelLiveVerificationUnlocked(displayID: displayID)
        liveVerificationSequence &+= 1
        let token = liveVerificationSequence
        liveVerificationTokens[displayID] = token

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.liveVerificationTokens[displayID] == token else { return }
            self.liveVerificationWorkItems[displayID] = nil
            self.liveVerificationTokens[displayID] = nil
            self.verifyLatestLiveWriteUnlocked(
                displayID: displayID,
                targetRawValue: targetRawValue,
                didReapply: didReapply
            )
            self.updateActivityUnlocked()
            self.reconcileDisplayRetryUnlocked()
            self.publishUnlocked()
        }
        liveVerificationWorkItems[displayID] = workItem
        queue.asyncAfter(
            deadline: .now() + Self.liveVerificationQuietPeriod,
            execute: workItem
        )
    }

    private func verifyLatestLiveWriteUnlocked(
        displayID: String,
        targetRawValue: UInt16,
        didReapply: Bool
    ) {
        guard phase == .syncing,
              let display = displays[displayID],
              let pending = sessionEntries[displayID],
              pending.pendingRawValue == targetRawValue else { return }

        let readback: (current: UInt16, maximum: UInt16)
        do {
            readback = try ddc.readBrightness(display)
            rawValues[displayID] = readback
        } catch {
            markTargetForAutomaticRetryUnlocked(
                displayID: displayID,
                targetRawValue: targetRawValue
            )
            displayErrors[displayID] = "Could not verify the latest brightness yet. Retrying automatically."
            logger.notice("Deferred brightness read failed for \(display.name, privacy: .public), target \(targetRawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        if readback.current == targetRawValue {
            var confirmed = pending
            confirmed.confirmWrite(targetRawValue)
            do {
                _ = try journalStore.upsert(confirmed)
                sessionEntries[displayID] = confirmed
                writeRetryStates[displayID] = nil
                displayErrors[displayID] = nil
                logger.debug("Confirmed newest live target for \(display.name, privacy: .public): \(targetRawValue, privacy: .public)/\(readback.maximum, privacy: .public)")
            } catch {
                displayErrors[displayID] = "Brightness changed, but its recovery record could not be updated: \(error.localizedDescription)"
                logger.error("Could not confirm the recovery journal for \(display.name, privacy: .public), target \(targetRawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        guard !didReapply else {
            markTargetForAutomaticRetryUnlocked(
                displayID: displayID,
                targetRawValue: targetRawValue
            )
            displayErrors[displayID] = "The monitor reported brightness \(readback.current) after target \(targetRawValue). Retrying automatically."
            logger.notice("Deferred brightness verification mismatch for \(display.name, privacy: .public): target \(targetRawValue, privacy: .public), received \(readback.current, privacy: .public)")
            return
        }

        do {
            try ddc.writeBrightness(
                display,
                value: targetRawValue,
                knownMaximum: readback.maximum,
                verify: false
            )
            rawValues[displayID] = (
                current: targetRawValue,
                maximum: readback.maximum
            )
            lastLiveWriteUptime[displayID] = ProcessInfo.processInfo.systemUptime
            displayErrors[displayID] = nil
            logger.notice("Reapplied newest live target for \(display.name, privacy: .public) after delayed readback: target \(targetRawValue, privacy: .public), received \(readback.current, privacy: .public)")
            scheduleLiveVerificationUnlocked(
                displayID: displayID,
                targetRawValue: targetRawValue,
                didReapply: true
            )
        } catch {
            markTargetForAutomaticRetryUnlocked(
                displayID: displayID,
                targetRawValue: targetRawValue
            )
            displayErrors[displayID] = "The monitor did not accept the latest brightness. Retrying automatically."
            logger.notice("Live target reapply failed for \(display.name, privacy: .public), target \(targetRawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelLiveVerificationUnlocked(displayID: String) {
        liveVerificationWorkItems.removeValue(forKey: displayID)?.cancel()
        liveVerificationTokens[displayID] = nil
    }

    private func cancelAllLiveVerificationsUnlocked() {
        for workItem in liveVerificationWorkItems.values {
            workItem.cancel()
        }
        liveVerificationWorkItems.removeAll()
        liveVerificationTokens.removeAll()
    }

    /// A final restore must not race firmware that is still applying the last
    /// fast live SET. Sleeping releases the CPU; this is not busy waiting.
    private func waitForLiveWriteToSettleUnlocked(displayID: String) {
        guard let writeUptime = lastLiveWriteUptime[displayID] else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - writeUptime
        let remaining = Self.liveVerificationQuietPeriod - elapsed
        if remaining > 0 {
            Thread.sleep(forTimeInterval: remaining)
        }
    }

    private func recordRetryableWriteFailureUnlocked(
        _ error: Error,
        displayID: String,
        targetRawValue: UInt16
    ) {
        markTargetForAutomaticRetryUnlocked(
            displayID: displayID,
            targetRawValue: targetRawValue
        )
        if displayRetrySchedule.hasPendingRetry(
            at: ProcessInfo.processInfo.systemUptime
        ) {
            displayErrors[displayID] = "\(error.localizedDescription) Retrying automatically."
        } else {
            displayErrors[displayID] = "\(error.localizedDescription) Choose Refresh Displays to try again."
        }
    }

    private func markTargetForAutomaticRetryUnlocked(
        displayID: String,
        targetRawValue: UInt16
    ) {
        let previousAttempts = writeRetryStates[displayID].flatMap {
            $0.rawValue == targetRawValue ? $0.attempts : nil
        } ?? 0
        let attempts = previousAttempts == Int.max ? Int.max : previousAttempts + 1
        writeRetryStates[displayID] = (targetRawValue, attempts)
        _ = scheduleDisplayRetryUnlocked()
    }

    private func captureBaselineIfNeededUnlocked(
        for display: DDCDisplay
    ) throws -> RestoreJournalEntry {
        if let entry = sessionEntries[display.id] {
            return entry
        }
        let readStarted = ProcessInfo.processInfo.systemUptime
        let current: (current: UInt16, maximum: UInt16)
        do {
            current = try ddc.readBrightness(display)
        } catch {
            let readDuration = ProcessInfo.processInfo.systemUptime - readStarted
            logger.notice("Baseline DDC read failed for \(display.name, privacy: .public) after \(readDuration, format: .fixed(precision: 2)) seconds: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let readDuration = ProcessInfo.processInfo.systemUptime - readStarted
        if readDuration >= 1 {
            logger.notice("Baseline DDC read for \(display.name, privacy: .public) took \(readDuration, format: .fixed(precision: 2)) seconds")
        }
        rawValues[display.id] = current
        let entry = RestoreJournalEntry(
            identity: display.identity,
            originalRawValue: current.current,
            originalMaximumRawValue: current.maximum,
            sessionID: sessionID
        )
        // Durability is deliberately before the first hardware mutation.
        _ = try journalStore.upsert(entry)
        sessionEntries[display.id] = entry
        updateActivityUnlocked()
        return entry
    }

    private func restoreCurrentSessionUnlocked(
        displayID: String? = nil,
        pendingOnly: Bool = false
    ) -> [String] {
        let candidates = sessionEntries.values.filter {
            (displayID == nil || $0.identity.stableKey == displayID) &&
                (!pendingOnly || $0.state == .restorePending)
        }
        var failures: [String] = []
        for entry in candidates {
            let key = entry.identity.stableKey
            cancelLiveVerificationUnlocked(displayID: key)
            waitForLiveWriteToSettleUnlocked(displayID: key)
            guard let display = displays[key] else {
                blockedDisplays.insert(key)
                displayErrors[key] = "Original brightness restore is pending until this monitor reconnects."
                failures.append(profileNameUnlocked(for: entry.identity))
                continue
            }
            let restoreStarted = ProcessInfo.processInfo.systemUptime
            do {
                var pending = entry
                pending.markRestorePending()
                _ = try journalStore.upsert(pending)
                sessionEntries[key] = pending
                try restoreEntryUnlocked(pending, display: display)
                sessionEntries[key] = nil
                rawValues[key] = (
                    current: pending.originalRawValue,
                    maximum: pending.originalMaximumRawValue
                )
                estimatedNits[key] = nil
                clamps[key] = SyncClamp.none
                blockedDisplays.remove(key)
                displayErrors[key] = nil
                lastLiveWriteUptime[key] = nil
                let restoreDuration = ProcessInfo.processInfo.systemUptime - restoreStarted
                if restoreDuration >= 1 {
                    logger.notice("Brightness restore for \(display.name, privacy: .public) took \(restoreDuration, format: .fixed(precision: 2)) seconds")
                }
            } catch {
                let restoreDuration = ProcessInfo.processInfo.systemUptime - restoreStarted
                logger.notice("Brightness restore failed for \(display.name, privacy: .public) after \(restoreDuration, format: .fixed(precision: 2)) seconds: \(error.localizedDescription, privacy: .public)")
                blockedDisplays.insert(key)
                displayErrors[key] = "Restore failed: \(error.localizedDescription)"
                failures.append(display.name)
            }
        }
        updateActivityUnlocked()
        return failures
    }

    private func pendingRestoreNamesUnlocked() -> [String] {
        do {
            return try journalStore.load().entries.map {
                profileNameUnlocked(for: $0.identity)
            }
        } catch {
            return ["Recovery journal (\(error.localizedDescription))"]
        }
    }

    @discardableResult
    private func restoreEntryUnlocked(
        _ entry: RestoreJournalEntry,
        display: DDCDisplay
    ) throws -> Bool {
        try ddc.writeBrightness(
            display,
            value: entry.originalRawValue,
            knownMaximum: entry.originalMaximumRawValue,
            verify: true
        )
        _ = try journalStore.removeEntry(
            for: entry.identity,
            sessionID: entry.sessionID
        )
        return true
    }

    private func profileUnlocked(for display: DDCDisplay) -> DisplayProfile? {
        profiles.profile(for: display.identity)
    }

    private func profileNameUnlocked(for identity: ExternalDisplayIdentity) -> String {
        profiles.profile(for: identity)?.name ?? "External Display"
    }

    private func updateActivityUnlocked() {
        let hasPendingJournal = ((try? journalStore.load().entries.isEmpty) == false)
        if hasPendingJournal, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "External display brightness must be restored before termination"
            )
        } else if !hasPendingJournal, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func makeSnapshotUnlocked() -> SyncAppSnapshot {
        let pendingIdentities = (try? journalStore.load().entries.map(\.identity)) ?? []
        let statuses = displays.values.map { display -> ExternalDisplayStatus in
            let profile = profileUnlocked(for: display)
            let raw = rawValues[display.id]
            let detectedMaximum = EDIDLuminance.maximumNits(from: display.edidData) ?? 350
            return ExternalDisplayStatus(
                id: display.id,
                name: display.name,
                identity: display.identity,
                currentRawValue: raw?.current,
                maximumRawValue: raw?.maximum,
                estimatedNits: estimatedNits[display.id],
                minimumNits: profile?.calibration.minimumNits ?? 30,
                maximumNits: profile?.calibration.maximumNits ?? detectedMaximum,
                calibrationPointCount: profile?.calibration.points.count ?? 0,
                isEnabled: profile?.isEnabled ?? false,
                isReady: profile != nil && raw != nil,
                clamp: clamps[display.id] ?? .none,
                error: displayErrors[display.id],
                hasPendingRestore: pendingIdentities.contains {
                    $0.matchesForPersistence(display.identity)
                },
                isBlocked: blockedDisplays.contains(display.id)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let calibrationStatus = calibration.map {
            let raw = rawValues[$0.displayID]
            return CalibrationStatus(
                displayID: $0.displayID,
                displayName: $0.displayName,
                identity: $0.identity,
                points: $0.points,
                currentRawValue: raw?.current,
                maximumRawValue: raw?.maximum,
                isBlocked: blockedDisplays.contains($0.displayID)
            )
        }
        let diagnosticMessage = message
            ?? (wakeRecoveryWorkItem != nil
                ? "Waiting briefly for display hardware after wake."
                : nil)
            ?? (isRetryingDisplays ? "Waiting for display hardware; retrying automatically." : nil)
            ?? {
                guard syncEnabled else { return nil }
                switch phase {
                case .paused:
                    return isSystemPaused
                        ? "Sync is temporarily paused (system event)."
                        : "Sync is paused. Open the monitor entry for last reported error."
                case .syncing where !blockedDisplays.isEmpty:
                    return "Some displays are paused while resolving writes. Open each monitor for details."
                case .quiescing, .starting, .stopped:
                    return nil
                case .calibrating:
                    return nil
                default:
                    return nil
                }
            }()

        return SyncAppSnapshot(
            phase: phase,
            sourceName: nitsReader.builtInDisplayName ?? "Built-in Display",
            sourceNits: sourceNits ?? nitsReader.currentNits(),
            syncEnabled: syncEnabled,
            lowLatencySync: lowLatencySync,
            displays: statuses,
            calibration: calibrationStatus,
            message: diagnosticMessage
        )
    }

    private func publishUnlocked() {
        guard let stateHandler else { return }
        let snapshot = makeSnapshotUnlocked()
        DispatchQueue.main.async {
            stateHandler(snapshot)
        }
    }

    private static func complete<T>(
        _ completion: ((Result<T, Error>) -> Void)?,
        with result: Result<T, Error>
    ) {
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
