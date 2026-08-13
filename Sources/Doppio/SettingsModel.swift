import SwiftUI
import ServiceManagement

/// Bridges the Preferences window (SwiftUI) to `Preferences` (UserDefaults) and
/// the live `AwakeCoordinator`. Each edit persists and triggers the matching
/// coordinator side effect; `reload()` refreshes from disk without firing them.
@MainActor
final class SettingsModel: ObservableObject {
    private let prefs = Preferences.shared
    private let coordinator: AwakeCoordinator
    private var loading = false

    // General
    @Published var keepDisplayOn = false      { didSet { commit { prefs.keepDisplayOn = keepDisplayOn; coordinator.optionsChanged() } } }
    @Published var pauseOnBattery = false      { didSet { commit { prefs.pauseOnBattery = pauseOnBattery; coordinator.optionsChanged() } } }
    @Published var batteryFloor = 30           { didSet { commit { prefs.batteryFloorPercent = batteryFloor; coordinator.optionsChanged() } } }
    @Published var allowLidClosed = false      { didSet { commit { prefs.allowLidClosed = allowLidClosed; coordinator.optionsChanged() } } }
    @Published var notificationsEnabled = true { didSet { commit { prefs.notificationsEnabled = notificationsEnabled } } }
    @Published var startAtLogin = false        { didSet { commit { setLogin(startAtLogin) } } }

    // Hotkey
    @Published var hotkeyEnabled = true        { didSet { commit { prefs.globalHotkeyEnabled = hotkeyEnabled; applyHotkey() } } }
    @Published var hotkeyDisplay = ""

    // Integrations
    @Published var claude = true   { didSet { commitMonitor { prefs.integrationClaude = claude } } }
    @Published var omp = true      { didSet { commitMonitor { prefs.integrationOmp = omp } } }
    @Published var opencode = true { didSet { commitMonitor { prefs.integrationOpencode = opencode } } }
    @Published var codex = true    { didSet { commitMonitor { prefs.integrationCodex = codex } } }
    @Published var gemini = true   { didSet { commitMonitor { prefs.integrationGemini = gemini } } }
    @Published var customProcesses = "" { didSet { commitMonitor {
        prefs.customProcesses = customProcesses
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    } } }

    // Schedule
    @Published var scheduleEnabled = false { didSet { commit { prefs.scheduleEnabled = scheduleEnabled; coordinator.optionsChanged() } } }
    @Published var scheduleStart = Date()  { didSet { commit { prefs.scheduleStartMinutes = Self.minutes(scheduleStart); coordinator.optionsChanged() } } }
    @Published var scheduleEnd = Date()    { didSet { commit { prefs.scheduleEndMinutes = Self.minutes(scheduleEnd); coordinator.optionsChanged() } } }
    @Published var weekdays: Set<Int> = [] { didSet { commit { prefs.scheduleWeekdays = weekdays.sorted(); coordinator.optionsChanged() } } }

    // Advanced
    @Published var graceSeconds = 90.0 { didSet { commit { prefs.graceSeconds = graceSeconds } } }
    @Published var pollSeconds = 5.0   { didSet { commit { prefs.pollSeconds = pollSeconds; coordinator.restartMonitor() } } }

    init(coordinator: AwakeCoordinator) {
        self.coordinator = coordinator
        reload()
    }

    /// Refresh all fields from persisted preferences without side effects.
    func reload() {
        loading = true
        defer { loading = false }
        keepDisplayOn = prefs.keepDisplayOn
        pauseOnBattery = prefs.pauseOnBattery
        batteryFloor = prefs.batteryFloorPercent
        allowLidClosed = prefs.allowLidClosed
        notificationsEnabled = prefs.notificationsEnabled
        startAtLogin = Self.isLoginEnabled()
        hotkeyEnabled = prefs.globalHotkeyEnabled
        hotkeyDisplay = HotKeyManager.display(modifiers: UInt32(prefs.hotKeyModifiers), label: prefs.hotKeyLabel)
        claude = prefs.integrationClaude
        omp = prefs.integrationOmp
        opencode = prefs.integrationOpencode
        codex = prefs.integrationCodex
        gemini = prefs.integrationGemini
        customProcesses = prefs.customProcesses.joined(separator: "\n")
        scheduleEnabled = prefs.scheduleEnabled
        scheduleStart = Self.dateFor(prefs.scheduleStartMinutes)
        scheduleEnd = Self.dateFor(prefs.scheduleEndMinutes)
        weekdays = Set(prefs.scheduleWeekdays)
        graceSeconds = prefs.graceSeconds
        pollSeconds = prefs.pollSeconds
    }

    func changeHotkey() {
        guard let hk = HotKeyRecorder.record(current: hotkeyDisplay) else { return }
        prefs.hotKeyCode = Int(hk.keyCode)
        prefs.hotKeyModifiers = Int(hk.modifiers)
        prefs.hotKeyLabel = hk.label
        hotkeyDisplay = HotKeyManager.display(modifiers: hk.modifiers, label: hk.label)
        prefs.globalHotkeyEnabled = true
        loading = true; hotkeyEnabled = true; loading = false
        applyHotkey()
    }

    // MARK: - Helpers

    private func commit(_ work: () -> Void) {
        guard !loading else { return }
        work()
    }

    private func commitMonitor(_ work: () -> Void) {
        guard !loading else { return }
        work()
        coordinator.reconfigureMonitor()
    }

    private func applyHotkey() {
        if prefs.globalHotkeyEnabled {
            HotKeyManager.shared.register(keyCode: UInt32(prefs.hotKeyCode),
                                          modifiers: UInt32(prefs.hotKeyModifiers))
        } else {
            HotKeyManager.shared.unregister()
        }
    }

    private static func isLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Doppio: login item change failed: %@", error.localizedDescription)
            // Reflect the real state back into the toggle.
            loading = true; startAtLogin = Self.isLoginEnabled(); loading = false
        }
    }

    static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func dateFor(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60,
                              second: 0, of: Date()) ?? Date()
    }
}
