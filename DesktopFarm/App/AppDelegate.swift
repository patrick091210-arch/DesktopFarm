import AppKit

/// Handles launch, Finder "open" of game files, and saving on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when launched as an XCTest host: never touch the real Desktop then.
    private var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            guard !isRunningTests else { return }
            GameCoordinator.shared.bootstrap()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            GameCoordinator.shared.handleOpen(urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            GameCoordinator.shared.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
