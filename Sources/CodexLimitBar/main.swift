import AppKit
import Darwin

if CommandLine.arguments.contains(ClaudeCodeIntegration.commandArgument) {
    exit(ClaudeCodeIntegration.captureStatusLineInput() ? EXIT_SUCCESS : EXIT_FAILURE)
}

PreferencesMigration.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
        statusBarController = nil
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
