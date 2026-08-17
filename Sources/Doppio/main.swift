// SPDX-License-Identifier: Apache-2.0
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
if CommandLine.arguments.contains("--install-lid-helper") {
    let ok = LidSleepHelper.shared.install()
    print("lid helper install: \(ok ? "ok" : "failed/cancelled") (\(LidSleepHelper.plistPath))")
    exit(ok ? 0 : 1)
}
if CommandLine.arguments.contains("--uninstall-lid-helper") {
    let ok = LidSleepHelper.shared.uninstall()
    print("lid helper uninstall: \(ok ? "ok" : "failed/cancelled")")
    exit(ok ? 0 : 1)
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
        setUpHotkey()

        coordinator.start()
        installSignalHandlers()
    }

    /// Register the global hotkey at launch. `RegisterEventHotKey` can fail if
    /// the combination is momentarily held by another login item during the
    /// login storm, so one failure is retried shortly. A persistent conflict is
    /// surfaced (log + HUD) instead of being silently ignored; the preference is
    /// left as intent so it self-heals once the conflict clears, and the
    /// Preferences "Change…" flow lets the user pick another combination.
    private func setUpHotkey() {
        guard Preferences.shared.globalHotkeyEnabled else { return }
        if registerHotkey() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self,
                  Preferences.shared.globalHotkeyEnabled,
                  !HotKeyManager.shared.isRegistered else { return }
            if !self.registerHotkey() {
                NSLog("Doppio: global hotkey could not be registered (in use by another app)")
                HUD.shared.show(symbol: "exclamationmark.triangle.fill",
                                text: "Shortcut in use")
            }
        }
    }

    @discardableResult
    private func registerHotkey() -> Bool {
        HotKeyManager.shared.register(
            keyCode: UInt32(Preferences.shared.hotKeyCode),
            modifiers: UInt32(Preferences.shared.hotKeyModifiers))
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
