import AppKit

// A headless self-test used by build.sh / CI to prove the IOKit power
// assertion actually registers with the system. Verifiable via
// `pmset -g assertions`.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = AwakeCoordinator()
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MenuController(coordinator: coordinator)
        coordinator.start()
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }

    /// Restore normal sleep behavior even if killed with SIGINT/SIGTERM
    /// (e.g. launched from a terminal during development).
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            Self.signalSources.append(src)
        }
    }

    private static var signalSources: [DispatchSourceSignal] = []
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
