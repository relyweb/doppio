import Foundation

/// User-configurable settings persisted in `UserDefaults`.
///
/// Runtime state (manual toggle, active timer) is intentionally NOT persisted:
/// the app always launches in an "off" state so a crash or reboot can never
/// leave the Mac permanently unable to sleep.
final class Preferences {
    static let shared = Preferences()

    private let store = UserDefaults.standard

    private enum Key {
        static let keepDisplayOn      = "keepDisplayOn"
        static let allowLidClosed     = "allowLidClosed"
        static let pauseOnBattery     = "pauseOnBattery"
        static let integrationClaude  = "integrationClaude"
        static let integrationOmp     = "integrationOmp"
        static let integrationOpencode = "integrationOpencode"
        static let integrationCodex   = "integrationCodex"
        static let integrationGemini  = "integrationGemini"
        static let customProcesses    = "customProcesses"
        static let graceSeconds       = "graceSeconds"
        static let pollSeconds        = "pollSeconds"
        static let notificationsEnabled = "notificationsEnabled"
        static let globalHotkeyEnabled  = "globalHotkeyEnabled"
        static let hotKeyCode       = "hotKeyCode"
        static let hotKeyModifiers  = "hotKeyModifiers"
        static let hotKeyLabel      = "hotKeyLabel"
        static let scheduleEnabled      = "scheduleEnabled"
        static let scheduleStartMinutes = "scheduleStartMinutes"
        static let scheduleEndMinutes   = "scheduleEndMinutes"
        static let scheduleWeekdays     = "scheduleWeekdays"
    }

    private init() {
        store.register(defaults: [
            Key.keepDisplayOn: false,
            Key.allowLidClosed: false,
            Key.pauseOnBattery: false,
            Key.integrationClaude: true,
            Key.integrationOmp: true,
            Key.integrationOpencode: true,
            Key.integrationCodex: true,
            Key.integrationGemini: true,
            Key.customProcesses: [String](),
            Key.graceSeconds: 90.0,
            Key.pollSeconds: 5.0,
            Key.notificationsEnabled: true,
            Key.globalHotkeyEnabled: true,
            Key.hotKeyCode: 40,            // kVK_ANSI_K
            Key.hotKeyModifiers: 6400,     // control(4096)+option(2048)+cmd(256)
            Key.hotKeyLabel: "K",
            Key.scheduleEnabled: false,
            Key.scheduleStartMinutes: 540,   // 09:00
            Key.scheduleEndMinutes: 1080,    // 18:00
            Key.scheduleWeekdays: [2, 3, 4, 5, 6],  // Mon–Fri (Calendar weekday)
        ])
    }

    /// Keep the display awake too (otherwise only the system stays awake).
    var keepDisplayOn: Bool {
        get { store.bool(forKey: Key.keepDisplayOn) }
        set { store.set(newValue, forKey: Key.keepDisplayOn) }
    }

    /// Prevent sleep even when the lid is closed (requires admin authorization).
    var allowLidClosed: Bool {
        get { store.bool(forKey: Key.allowLidClosed) }
        set { store.set(newValue, forKey: Key.allowLidClosed) }
    }

    /// Suppress keep-awake entirely while running on battery (saves charge and
    /// avoids heat build-up, especially with the lid closed).
    var pauseOnBattery: Bool {
        get { store.bool(forKey: Key.pauseOnBattery) }
        set { store.set(newValue, forKey: Key.pauseOnBattery) }
    }

    var integrationClaude: Bool {
        get { store.bool(forKey: Key.integrationClaude) }
        set { store.set(newValue, forKey: Key.integrationClaude) }
    }

    var integrationOmp: Bool {
        get { store.bool(forKey: Key.integrationOmp) }
        set { store.set(newValue, forKey: Key.integrationOmp) }
    }

    var integrationOpencode: Bool {
        get { store.bool(forKey: Key.integrationOpencode) }
        set { store.set(newValue, forKey: Key.integrationOpencode) }
    }

    var integrationCodex: Bool {
        get { store.bool(forKey: Key.integrationCodex) }
        set { store.set(newValue, forKey: Key.integrationCodex) }
    }

    var integrationGemini: Bool {
        get { store.bool(forKey: Key.integrationGemini) }
        set { store.set(newValue, forKey: Key.integrationGemini) }
    }

    /// Extra process-name tokens the user wants to treat as agentic tasks.
    var customProcesses: [String] {
        get { store.array(forKey: Key.customProcesses) as? [String] ?? [] }
        set { store.set(newValue, forKey: Key.customProcesses) }
    }

    /// How long to keep the Mac awake after an integration process disappears.
    var graceSeconds: TimeInterval {
        get { store.double(forKey: Key.graceSeconds) }
        set { store.set(newValue, forKey: Key.graceSeconds) }
    }

    /// How often the activity monitor polls the process table.
    var pollSeconds: TimeInterval {
        get { max(1.0, store.double(forKey: Key.pollSeconds)) }
        set { store.set(newValue, forKey: Key.pollSeconds) }
    }

    /// Post a notification when a timer or scheduled window ends.
    var notificationsEnabled: Bool {
        get { store.bool(forKey: Key.notificationsEnabled) }
        set { store.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// Register the global ⌃⌥⌘K toggle hotkey.
    var globalHotkeyEnabled: Bool {
        get { store.bool(forKey: Key.globalHotkeyEnabled) }
        set { store.set(newValue, forKey: Key.globalHotkeyEnabled) }
    }

    /// Global hotkey: virtual key code, Carbon modifier mask, and a display
    /// label (e.g. "K", "F5", "Space") captured when the user records it.
    var hotKeyCode: Int {
        get { store.integer(forKey: Key.hotKeyCode) }
        set { store.set(newValue, forKey: Key.hotKeyCode) }
    }
    var hotKeyModifiers: Int {
        get { store.integer(forKey: Key.hotKeyModifiers) }
        set { store.set(newValue, forKey: Key.hotKeyModifiers) }
    }
    var hotKeyLabel: String {
        get { store.string(forKey: Key.hotKeyLabel) ?? "K" }
        set { store.set(newValue, forKey: Key.hotKeyLabel) }
    }

    /// Keep the Mac awake during a recurring weekly window.
    var scheduleEnabled: Bool {
        get { store.bool(forKey: Key.scheduleEnabled) }
        set { store.set(newValue, forKey: Key.scheduleEnabled) }
    }

    /// Window start/end as minutes from midnight.
    var scheduleStartMinutes: Int {
        get { store.integer(forKey: Key.scheduleStartMinutes) }
        set { store.set(newValue, forKey: Key.scheduleStartMinutes) }
    }
    var scheduleEndMinutes: Int {
        get { store.integer(forKey: Key.scheduleEndMinutes) }
        set { store.set(newValue, forKey: Key.scheduleEndMinutes) }
    }

    /// Active weekdays as `Calendar` weekday numbers (1=Sun … 7=Sat).
    var scheduleWeekdays: [Int] {
        get { store.array(forKey: Key.scheduleWeekdays) as? [Int] ?? [] }
        set { store.set(newValue, forKey: Key.scheduleWeekdays) }
    }
}
