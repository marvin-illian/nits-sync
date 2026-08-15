import AppKit
import ServiceManagement

final class StatusMenuController: NSObject, NSMenuDelegate {
    private static let appName = "Nits Sync"
    private static let iconRevealDuration: TimeInterval = 5
    private let coordinator: DisplaySyncCoordinator
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var snapshot: SyncAppSnapshot?
    private var hideTimer: Timer?
    private var menuIsOpen = false
    private var menuNeedsRebuild = false
    private var resetInProgress = false
    private weak var sourceStatusItem: NSMenuItem?
    private var displayTopLevelItemsByID: [String: NSMenuItem] = [:]
    private weak var calibrationBrightnessSlider: NSSlider?
    private weak var calibrationBrightnessLabel: NSMenuItem?
    private weak var calibrationRecordItem: NSMenuItem?
    private weak var calibrationFinishItem: NSMenuItem?
    private weak var calibrationCancelItem: NSMenuItem?

    init(coordinator: DisplaySyncCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = "NitsSync.StatusItem"
        statusItem.isVisible = true
        statusItem.button?.image = Self.statusImage()
        statusItem.button?.toolTip = Self.appName
        statusItem.menu = menu
        menu.delegate = self
        rebuildMenu()

        if UserDefaults.standard.bool(forKey: Preferences.autoHideIcon) {
            revealTemporarily()
        }
    }

    func update(_ snapshot: SyncAppSnapshot) {
        self.snapshot = snapshot
        if snapshot.calibration != nil {
            hideTimer?.invalidate()
            hideTimer = nil
            statusItem.isVisible = true
        }
        updateSourceStatus(from: snapshot)
        updateCalibrationBrightnessControls(from: snapshot.calibration)
        updateDisplayStatus(from: snapshot.displays)
        requestMenuRebuild()
        updateToolTip()
    }

    func revealTemporarily() {
        statusItem.isVisible = true
        scheduleHideIfNeeded()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menuNeedsRebuild {
            rebuildMenu()
        }
        menuIsOpen = true
        hideTimer?.invalidate()
        hideTimer = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if menuNeedsRebuild {
            rebuildMenu()
        }
        scheduleHideIfNeeded()
    }

    @objc private func toggleSync(_ sender: NSMenuItem) {
        let shouldEnable = !(snapshot?.syncEnabled ?? false)
        sender.isEnabled = false
        coordinator.setSyncEnabled(shouldEnable) { [weak self] result in
            if case let .failure(error) = result {
                self?.showError(error)
            }
        }
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let display = snapshot?.displays.first(where: { $0.id == id }) else {
            return
        }
        coordinator.setDisplayEnabled(!display.isEnabled, displayID: id)
    }

    @objc private func editMaximumNits(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let display = snapshot?.displays.first(where: { $0.id == id }) else {
            return
        }

        let field = NSTextField(string: String(format: "%.1f", display.maximumNits))
        field.placeholderString = "Maximum nits"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)

        let alert = NSAlert()
        alert.messageText = "Maximum luminance for \(display.name)"
        alert.informativeText = "Enter the monitor's SDR maximum in nits. The current curve will be rescaled; use calibration afterward for the closest match."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let normalized = field.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else {
            showErrorText("Enter a positive number of nits.")
            return
        }
        coordinator.setMaximumNits(value, displayID: id)
    }

    @objc private func beginCalibration(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let display = snapshot?.displays.first(where: { $0.id == id }) else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Calibrate \(display.name)"
        alert.informativeText = "Sync pauses during calibration and white reference patches appear on the displays. At low, middle, and high brightness, set the Mac with its brightness keys, match the patches with the External Brightness slider, then record the match. Keep HDR and energy-saving modes unchanged."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.beginCalibration(displayID: id) { [weak self] result in
            if case let .failure(error) = result {
                self?.showError(error)
            }
        }
    }

    @objc private func recordCalibrationPoint(_ sender: NSMenuItem) {
        sender.isEnabled = false
        coordinator.recordCalibrationPoint { [weak self] result in
            if case let .failure(error) = result {
                sender.isEnabled = self?.canAdjustCurrentCalibration ?? false
                self?.showError(error)
            }
        }
    }

    @objc private func setCalibrationBrightness(_ sender: NSSlider) {
        let rounded = sender.doubleValue.rounded(.toNearestOrAwayFromZero)
        let clamped = min(max(rounded, sender.minValue), sender.maxValue)
        let rawValue = UInt16(clamping: Int(clamped))
        sender.doubleValue = Double(rawValue)
        updateCalibrationBrightnessLabel(
            current: rawValue,
            maximum: UInt16(clamping: Int(sender.maxValue))
        )
        sender.isEnabled = false

        coordinator.setCalibrationBrightness(rawValue) { [weak self, weak sender] result in
            sender?.isEnabled = self?.canAdjustCurrentCalibration ?? false
            if case let .failure(error) = result {
                self?.showError(error)
            }
        }
    }

    @objc private func finishCalibration(_ sender: NSMenuItem) {
        sender.isEnabled = false
        coordinator.finishCalibration { [weak self] result in
            if case let .failure(error) = result {
                sender.isEnabled = self?.canFinishCurrentCalibration ?? false
                self?.showError(error)
            }
        }
    }

    @objc private func cancelCalibration(_ sender: NSMenuItem) {
        sender.isEnabled = false
        coordinator.cancelCalibration { [weak self, weak sender] result in
            if case let .failure(error) = result {
                sender?.isEnabled = self?.isCalibrationPhaseInteractive ?? false
                self?.showError(error)
            }
        }
    }

    @objc private func resetCalibration(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let display = snapshot?.displays.first(where: { $0.id == id }) else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reset \(display.name)'s calibration?"
        alert.informativeText = "This removes recorded match points and returns to the EDID-derived maximum with a 30-nit low-end estimate."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            coordinator.resetCalibration(displayID: id)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                showLoginApproval()
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    showLoginApproval()
                }
            @unknown default:
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(error)
        }
        requestMenuRebuild()
    }

    @objc private func toggleAutoHide(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: Preferences.autoHideIcon)
        UserDefaults.standard.set(enabled, forKey: Preferences.autoHideIcon)
        if enabled {
            scheduleHideIfNeeded()
        } else {
            hideTimer?.invalidate()
            hideTimer = nil
            statusItem.isVisible = true
        }
        requestMenuRebuild()
    }

    @objc private func toggleLowLatencySync(_ sender: NSMenuItem) {
        coordinator.setLowLatencySyncEnabled(sender.state != .on)
    }

    @objc private func refreshDisplays(_ sender: NSMenuItem) {
        coordinator.refreshDisplays()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func resetApplication(_ sender: NSMenuItem) {
        guard !resetInProgress else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
            alert.messageText = "Reset \(Self.appName)?"
            alert.informativeText = "This restores every monitor controlled by \(Self.appName), turns off Start at Login, deletes all saved monitor calibrations, settings, and recovery data, then quits. The \(Self.appName) app itself stays installed."
            alert.addButton(withTitle: "Reset & Quit")
            alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        resetInProgress = true
        coordinator.shutdown { [weak self] result in
            DispatchQueue.main.async {
                self?.finishReset(after: result)
            }
        }
    }

    private func rebuildMenu() {
        menuNeedsRebuild = false
        displayTopLevelItemsByID.removeAll()
        sourceStatusItem = nil
        calibrationBrightnessSlider = nil
        calibrationBrightnessLabel = nil
        calibrationRecordItem = nil
        calibrationFinishItem = nil
        calibrationCancelItem = nil
        menu.removeAllItems()

        if let snapshot {
            sourceStatusItem = addItem(Self.sourceTitle(for: snapshot), enabled: false)

            let syncTitle: String
            switch snapshot.phase {
            case .starting: syncTitle = "Starting…"
            case .quiescing: syncTitle = "Restoring displays…"
            case .calibrating: syncTitle = "Sync Brightness (calibrating)"
            default: syncTitle = "Sync Brightness"
            }
            let sync = addItem(syncTitle, action: #selector(toggleSync(_:)))
            sync.state = snapshot.syncEnabled ? .on : .off
            sync.isEnabled = snapshot.phase != .starting &&
                snapshot.phase != .quiescing &&
                snapshot.calibration == nil

            if let calibration = snapshot.calibration {
                addCalibrationMenu(calibration)
            } else {
                addDisplayMenus(snapshot.displays)
            }

            if snapshot.calibration == nil, let message = snapshot.message {
                menu.addItem(.separator())
                addWrappedInfo(message)
            }
        } else {
            addItem("Starting \(Self.appName)…", enabled: false)
        }

        menu.addItem(.separator())
        addItem("Refresh Displays", action: #selector(refreshDisplays(_:)))
        let login = addItem("Start at Login", action: #selector(toggleLaunchAtLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval {
            login.title += " (approval needed)"
        }

        let autoHide = addItem("Hide Icon", action: #selector(toggleAutoHide(_:)))
        autoHide.state = UserDefaults.standard.bool(forKey: Preferences.autoHideIcon) ? .on : .off

        let lowLatency = addItem("Low-Latency Sync", action: #selector(toggleLowLatencySync(_:)))
        lowLatency.state = (snapshot?.lowLatencySync ?? false) ? .on : .off
        lowLatency.toolTip = "Reduce responsiveness delay for external monitor updates at the cost of more visible jitter."

        menu.addItem(.separator())
        addItem("Reset \(Self.appName)…", action: #selector(resetApplication(_:)))
        addItem("Quit \(Self.appName)…", action: #selector(quit(_:)))
    }

    private func addDisplayMenus(_ displays: [ExternalDisplayStatus]) {
        menu.addItem(.separator())
        guard !displays.isEmpty else {
            addItem("No readable DDC monitor found", enabled: false)
            return
        }

        for display in displays {
            let item = Self.item(Self.displayStatusTitle(for: display), representedObject: display.id)
            menu.addItem(item)
            displayTopLevelItemsByID[display.id] = item
            let submenu = NSMenu(title: display.name)
            item.submenu = submenu

            let rawText: String
            if let current = display.currentRawValue,
               let maximum = display.maximumRawValue {
                rawText = "Hardware brightness: \(current) / \(maximum)"
            } else {
                rawText = "Hardware brightness unavailable"
            }
            submenu.addItem(Self.item(rawText, enabled: false))
            submenu.addItem(Self.item(
                String(format: "Curve: %.1f–%.1f nits · %d points",
                       display.minimumNits,
                       display.maximumNits,
                       display.calibrationPointCount),
                enabled: false
            ))
            if display.hasPendingRestore {
                submenu.addItem(Self.item("Original value is safely journaled", enabled: false))
            }
            if let error = display.error {
                submenu.addItem(.separator())
                submenu.addItem(Self.item("⚠ \(error)", enabled: false))
            }

            submenu.addItem(.separator())
            let enabled = Self.item(
                "Control This Display",
                action: #selector(toggleDisplay(_:)),
                target: self,
                representedObject: display.id
            )
            enabled.state = display.isEnabled ? .on : .off
            enabled.isEnabled = display.isReady
            submenu.addItem(enabled)
            let maximum = Self.item(
                "Set Maximum Nits…",
                action: #selector(editMaximumNits(_:)),
                target: self,
                representedObject: display.id
            )
            maximum.isEnabled = display.isReady
            submenu.addItem(maximum)
            let calibrate = Self.item(
                "Calibrate This Display…",
                action: #selector(beginCalibration(_:)),
                target: self,
                representedObject: display.id
            )
            calibrate.isEnabled = display.isReady &&
                !display.isBlocked &&
                canBeginCalibration
            submenu.addItem(calibrate)
            let reset = Self.item(
                "Reset to Detected Estimate…",
                action: #selector(resetCalibration(_:)),
                target: self,
                representedObject: display.id
            )
            reset.isEnabled = display.isReady && display.calibrationPointCount > 2
            submenu.addItem(reset)
        }
    }

    private func addCalibrationMenu(_ calibration: CalibrationStatus) {
        menu.addItem(.separator())
        addItem("Calibrating \(calibration.displayName)", enabled: false)
        addItem("1. Set the Mac with its brightness keys", enabled: false)
        addItem("2. Match the white patches with this slider", enabled: false)

        if calibration.isBlocked {
            addItem("⚠ Original brightness must be restored first", enabled: false)
        }

        if let current = calibration.currentRawValue,
           let maximum = calibration.maximumRawValue,
           maximum > 0 {
            let clampedCurrent = min(current, maximum)
            calibrationBrightnessLabel = addItem(
                Self.calibrationBrightnessTitle(
                    current: clampedCurrent,
                    maximum: maximum
                ),
                enabled: false
            )

            let slider = NSSlider(
                value: Double(clampedCurrent),
                minValue: 0,
                maxValue: Double(maximum),
                target: self,
                action: #selector(setCalibrationBrightness(_:))
            )
            slider.isContinuous = false
            slider.isEnabled = canAdjustCalibration(calibration)
            slider.toolTip = "External hardware brightness, 0 to \(maximum)"

            let sliderContainer = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
            slider.frame = NSRect(x: 14, y: 3, width: 252, height: 24)
            sliderContainer.addSubview(slider)

            let sliderItem = NSMenuItem()
            sliderItem.view = sliderContainer
            menu.addItem(sliderItem)
            calibrationBrightnessSlider = slider
        } else {
            addItem("External brightness unavailable", enabled: false)
        }

        addItem("3. Record low, middle, and high matches", enabled: false)

        for (index, point) in calibration.points.enumerated() {
            addItem(
                "Point \(index + 1): \(Int(point.nits.rounded())) nits ↔ \(point.rawValue)",
                enabled: false
            )
        }
        let record = addItem("Record Current Match", action: #selector(recordCalibrationPoint(_:)))
        record.keyEquivalent = "r"
        record.isEnabled = canAdjustCalibration(calibration)
        calibrationRecordItem = record
        let finish = addItem("Finish Calibration", action: #selector(finishCalibration(_:)))
        finish.isEnabled = calibration.points.count >= 3 && canAdjustCalibration(calibration)
        calibrationFinishItem = finish
        let cancel = addItem("Cancel Calibration", action: #selector(cancelCalibration(_:)))
        cancel.isEnabled = isCalibrationPhaseInteractive
        calibrationCancelItem = cancel
    }

    private func updateCalibrationBrightnessControls(from calibration: CalibrationStatus?) {
        guard let calibration else {
            calibrationBrightnessSlider?.isEnabled = false
            calibrationRecordItem?.isEnabled = false
            calibrationFinishItem?.isEnabled = false
            calibrationCancelItem?.isEnabled = false
            return
        }

        let canAdjust = canAdjustCalibration(calibration)
        calibrationBrightnessSlider?.isEnabled = canAdjust
        calibrationRecordItem?.isEnabled = canAdjust
        calibrationFinishItem?.isEnabled = calibration.points.count >= 3 && canAdjust
        calibrationCancelItem?.isEnabled = isCalibrationPhaseInteractive

        guard let current = calibration.currentRawValue,
              let maximum = calibration.maximumRawValue,
              maximum > 0 else { return }

        let clampedCurrent = min(current, maximum)
        calibrationBrightnessSlider?.maxValue = Double(maximum)
        calibrationBrightnessSlider?.doubleValue = Double(clampedCurrent)
        updateCalibrationBrightnessLabel(current: clampedCurrent, maximum: maximum)
    }

    private func canAdjustCalibration(_ calibration: CalibrationStatus) -> Bool {
        isCalibrationPhaseInteractive &&
            !calibration.isBlocked &&
            calibration.currentRawValue != nil &&
            (calibration.maximumRawValue ?? 0) > 0
    }

    private var isCalibrationPhaseInteractive: Bool {
        guard let snapshot else { return false }
        if case .calibrating = snapshot.phase { return true }
        return false
    }

    private var canBeginCalibration: Bool {
        guard let snapshot else { return false }
        return snapshot.phase == .syncing || snapshot.phase == .paused
    }

    private var canAdjustCurrentCalibration: Bool {
        guard let calibration = snapshot?.calibration else { return false }
        return canAdjustCalibration(calibration)
    }

    private var canFinishCurrentCalibration: Bool {
        guard let calibration = snapshot?.calibration else { return false }
        return calibration.points.count >= 3 && canAdjustCalibration(calibration)
    }

    private func updateSourceStatus(from snapshot: SyncAppSnapshot) {
        sourceStatusItem?.title = Self.sourceTitle(for: snapshot)
    }

    private func updateDisplayStatus(from displays: [ExternalDisplayStatus]) {
        for display in displays {
            guard let item = displayTopLevelItemsByID[display.id] else { continue }
            item.title = Self.displayStatusTitle(for: display)

            if let submenu = item.submenu,
               let rawText = submenu.item(at: 0) {
                if let current = display.currentRawValue,
                   let maximum = display.maximumRawValue {
                    rawText.title = "Hardware brightness: \(current) / \(maximum)"
                } else {
                    rawText.title = "Hardware brightness unavailable"
                }
            }
        }
    }

    private static func displayStatusTitle(for display: ExternalDisplayStatus) -> String {
        if !display.isReady {
            return "\(display.name)  ·  connecting…"
        }
        if let nits = display.estimatedNits {
            let suffix = display.clamp == .maximum ? " · at maximum" :
                (display.clamp == .minimum ? " · at minimum" : "")
            return "\(display.name)  ·  ≈\(Int(nits.rounded())) nits\(suffix)"
        }
        if let current = display.currentRawValue,
           let maximum = display.maximumRawValue {
            return "\(display.name)  ·  \(current)/\(maximum)"
        }
        return display.name
    }

    private static func sourceTitle(for snapshot: SyncAppSnapshot) -> String {
        if let nits = snapshot.sourceNits {
            return "\(snapshot.sourceName)  ·  \(Int(nits.rounded())) nits"
        }
        return "\(snapshot.sourceName)  ·  reading nits…"
    }

    private func updateCalibrationBrightnessLabel(current: UInt16, maximum: UInt16) {
        calibrationBrightnessLabel?.title = Self.calibrationBrightnessTitle(
            current: current,
            maximum: maximum
        )
    }

    private static func calibrationBrightnessTitle(
        current: UInt16,
        maximum: UInt16
    ) -> String {
        guard maximum > 0 else { return "External Brightness" }
        let percent = Int((Double(current) / Double(maximum) * 100).rounded())
        return "External Brightness  ·  \(percent)%"
    }

    @discardableResult
    private func addItem(
        _ title: String,
        action: Selector? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = Self.item(title, action: action, target: self)
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    private func addWrappedInfo(_ text: String) {
        let shortened = text.count > 100 ? String(text.prefix(97)) + "…" : text
        addItem(shortened, enabled: false)
    }

    private func scheduleHideIfNeeded() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard UserDefaults.standard.bool(forKey: Preferences.autoHideIcon),
              !menuIsOpen,
              snapshot?.calibration == nil else { return }
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: Self.iconRevealDuration,
            repeats: false
        ) {
            [weak self] _ in
            self?.statusItem.isVisible = false
        }
    }

    private func updateToolTip() {
        guard let snapshot else {
            statusItem.button?.toolTip = Self.appName
            return
        }
        let nits = snapshot.sourceNits.map { "\(Int($0.rounded())) nits" } ?? "reading…"
        statusItem.button?.toolTip = "\(Self.appName) · \(nits)"
    }

    private func showError(_ error: Error) {
        showErrorText(error.localizedDescription)
    }

    private func showErrorText(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Self.appName
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func statusImage() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "sun.max.fill",
            accessibilityDescription: Self.appName
        )
        image?.isTemplate = true
        return image
    }

    private static func item(
        _ title: String,
        action: Selector? = nil,
        target: AnyObject? = nil,
        representedObject: Any? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = representedObject
        item.isEnabled = enabled
        return item
    }

    private func requestMenuRebuild() {
        if menuIsOpen {
            menuNeedsRebuild = true
        } else {
            rebuildMenu()
        }
    }

    private func showLoginApproval() {
        let alert = NSAlert()
        alert.messageText = "Approval is needed"
        alert.informativeText = "Allow \(Self.appName) under Login Items in System Settings."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func finishReset(after result: Result<Void, Error>) {
        switch result {
        case let .failure(error):
            resetInProgress = false
            coordinator.resumeAfterCancelledShutdown()
            showError(error)
        case .success:
            do {
                let loginStatus = SMAppService.mainApp.status
                if loginStatus != .notRegistered, loginStatus != .notFound {
                    try SMAppService.mainApp.unregister()
                }

                hideTimer?.invalidate()
                hideTimer = nil
                statusItem.autosaveName = nil
                try ApplicationSupport.removeAllGeneratedFiles()

                if let bundleIdentifier = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
                }
                UserDefaults.standard.synchronize()
                NSApp.terminate(nil)
            } catch {
                resetInProgress = false
                coordinator.resumeAfterCancelledShutdown()
                showError(error)
            }
        }
    }
}
