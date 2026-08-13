import AppKit

// A headless self-test used by build.sh / CI to prove the IOKit power
// assertion actually registers with the system. Verifiable via
// `pmset -g assertions`.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}
if CommandLine.arguments.contains("--selftest-modes") {
    SelfTest.runModes()
    exit(0)
}
if CommandLine.arguments.contains("--selftest-power") {
    SelfTest.runPower()
    exit(0)
}
if CommandLine.arguments.contains("--diag") {
    SelfTest.runDiag()
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-prefs"),
   i + 2 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        PreferencesRenderer.render(tab: CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2])
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-hud"),
   i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        HUD.renderForTest(to: CommandLine.arguments[i + 1])
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = AwakeCoordinator()
    private var menuController: MenuController?
    private lazy var notifier = Notifier { Preferences.shared.notificationsEnabled }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MenuController(coordinator: coordinator)

        // Surface coordinator events as notifications.
        notifier.requestAuthorization()
        coordinator.onEvent = { [weak self] event in
            switch event {
            case .timerExpired:
                self?.notifier.post(title: "Doppio",
                                    body: "Timer finished — sleep is allowed again.")
            case .watchEnded(let name):
                self?.notifier.post(title: "Doppio",
                                    body: "\(name) finished — sleep is allowed again.")
            case .scheduleEnded:
                self?.notifier.post(title: "Doppio",
                                    body: "Scheduled awake window ended.")
            }
        }

        // Global toggle hotkey (⌃⌥⌘K).
        HotKeyManager.shared.onFire = { [weak self] in
            guard let self else { return }
            let on = !self.coordinator.manualIndefinite
            self.coordinator.setManualIndefinite(on)
            HUD.shared.show(symbol: on ? "cup.and.saucer.fill" : "cup.and.saucer",
                            text: on ? "Keep Awake On" : "Keep Awake Off")
        }
        if Preferences.shared.globalHotkeyEnabled {
            HotKeyManager.shared.register(
                keyCode: UInt32(Preferences.shared.hotKeyCode),
                modifiers: UInt32(Preferences.shared.hotKeyModifiers))
        }

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
