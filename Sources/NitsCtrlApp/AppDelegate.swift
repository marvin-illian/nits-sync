import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = DisplaySyncCoordinator()
    private let calibrationReferences = CalibrationReferenceWindowController()
    private var statusMenu: StatusMenuController?
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationInProgress = false
    private var terminationApproved = false
    private var poweringOff = false
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusMenu = StatusMenuController(coordinator: coordinator)
        coordinator.start { [weak self] snapshot in
            self?.statusMenu?.update(snapshot)
            self?.calibrationReferences.update(snapshot)
        }
        installLifecycleObservers()
        installTerminationSignalHandler()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusMenu?.revealTemporarily()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved {
            return .terminateNow
        }
        guard !terminationInProgress else {
            return .terminateLater
        }
        beginTerminationRestore()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        calibrationReferences.closeAll()
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        signalSource?.cancel()
        signalSource = nil
    }

    private func beginTerminationRestore() {
        terminationInProgress = true
        coordinator.shutdown { [weak self] result in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            switch result {
            case .success:
                self.terminationApproved = true
                NSApp.reply(toApplicationShouldTerminate: true)
            case let .failure(error):
                if self.poweringOff {
                    // Never hold logout/shutdown indefinitely. The durable
                    // journal remains for recovery on the next launch.
                    self.terminationApproved = true
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                self.handleRestoreFailure(error)
            }
        }
    }

    private func handleRestoreFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "A monitor could not be restored"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel Quit")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            terminationInProgress = false
            beginTerminationRestore()
        case .alertSecondButtonReturn:
            terminationApproved = true
            NSApp.reply(toApplicationShouldTerminate: true)
        default:
            terminationInProgress = false
            coordinator.resumeAfterCancelledShutdown()
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.calibrationReferences.refreshScreens()
            self?.coordinator.refreshDisplays()
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let pauseNotifications: [(Notification.Name, SystemPauseReason)] = [
            (NSWorkspace.willSleepNotification, .sleep),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession),
        ]
        for (name, reason) in pauseNotifications {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.coordinator.pauseForSystemEvent(reason)
            })
        }
        let resumeNotifications: [(Notification.Name, SystemPauseReason)] = [
            (NSWorkspace.didWakeNotification, .sleep),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession),
        ]
        for (name, reason) in resumeNotifications {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.coordinator.resumeAfterSystemEvent(reason)
            })
        }
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.poweringOff = true
            self?.coordinator.pauseForSystemEvent(.powerOff)
        })
    }

    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        signalSource = source
    }
}
