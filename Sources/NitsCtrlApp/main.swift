import AppKit
import Foundation

Preferences.registerDefaults()

if CommandLine.arguments.contains("--probe") {
    exit(HardwareProbe.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
withExtendedLifetime(delegate) {
    application.run()
}
