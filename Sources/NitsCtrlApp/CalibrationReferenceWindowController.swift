import AppKit
import CoreGraphics
import NitsCtrlCore

extension Notification.Name {
    static let nitsCtrlCoordinatorWillShutdown = Notification.Name(
        "app.nits-sync.coordinator-will-shutdown"
    )
    static let nitsCtrlCoordinatorDidResumeAfterCancelledShutdown = Notification.Name(
        "app.nits-sync.coordinator-did-resume-after-cancelled-shutdown"
    )
}

/// Shows equal-size white patches on the built-in and calibrated displays.
///
/// When CoreGraphics cannot uniquely associate the selected DDC identity with
/// an NSScreen (for example, two serial-less monitors of the same model), every
/// screen gets a patch rather than risking a patch on the wrong display.
final class CalibrationReferenceWindowController {
    private static let patchSize = NSSize(width: 360, height: 240)

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var latestSnapshot: SyncAppSnapshot?
    private var isSuppressedForShutdown = false
    private var observers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        observers.append(notificationCenter.addObserver(
            forName: .nitsCtrlCoordinatorWillShutdown,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSuppressedForShutdown = true
            self?.closeAll()
        })
        observers.append(notificationCenter.addObserver(
            forName: .nitsCtrlCoordinatorDidResumeAfterCancelledShutdown,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isSuppressedForShutdown = false
            self.reconcilePanels()
        })
    }

    deinit {
        closeAll()
        observers.forEach(notificationCenter.removeObserver)
    }

    func update(_ snapshot: SyncAppSnapshot) {
        latestSnapshot = snapshot
        if snapshot.calibration == nil {
            isSuppressedForShutdown = false
        }
        reconcilePanels()
    }

    func closeAll() {
        for panel in panels.values {
            panel.close()
        }
        panels.removeAll()
    }

    func refreshScreens() {
        reconcilePanels()
    }

    private func reconcilePanels() {
        guard !isSuppressedForShutdown,
              let snapshot = latestSnapshot,
              let calibration = snapshot.calibration,
              case .calibrating = snapshot.phase else {
            closeAll()
            return
        }

        let targetScreens = screensForCalibration(identity: calibration.identity)
        let targets = Dictionary(
            targetScreens.compactMap { screen in
                displayID(for: screen).map { ($0, screen) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        let obsoleteDisplayIDs = panels.keys.filter { targets[$0] == nil }
        for displayID in obsoleteDisplayIDs {
            panels.removeValue(forKey: displayID)?.close()
        }

        for (displayID, screen) in targets {
            let panel = panels[displayID] ?? makePanel()
            panels[displayID] = panel
            center(panel, on: screen)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    private func screensForCalibration(
        identity: ExternalDisplayIdentity
    ) -> [NSScreen] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        let builtInScreens = screens.filter { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }
        let externalScreens = screens.filter { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(displayID) == 0
        }

        let modelMatches = externalScreens.filter { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return CGDisplayVendorNumber(displayID) == identity.vendorID &&
                CGDisplayModelNumber(displayID) == identity.productID
        }

        let selectedMatches: [NSScreen]
        if let serial = identity.serialNumber,
           serial != 0,
           serial != UInt32.max {
            selectedMatches = modelMatches.filter { screen in
                guard let displayID = displayID(for: screen) else { return false }
                return CGDisplaySerialNumber(displayID) == serial
            }
        } else {
            selectedMatches = modelMatches
        }

        guard builtInScreens.count == 1, selectedMatches.count == 1 else {
            return screens
        }

        return [builtInScreens[0], selectedMatches[0]]
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.patchSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = CalibrationReferenceView(
            frame: NSRect(origin: .zero, size: Self.patchSize)
        )
        panel.backgroundColor = .white
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        return panel
    }

    private func center(_ panel: NSPanel, on screen: NSScreen) {
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - Self.patchSize.width / 2,
            y: frame.midY - Self.patchSize.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: Self.patchSize), display: false)
    }
}

private final class CalibrationReferenceView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        NSColor(calibratedWhite: 0.68, alpha: 1).setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}
