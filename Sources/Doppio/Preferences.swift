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
        static let integrationClaude  = "integrationClaude"
        static let integrationOmp     = "integrationOmp"
        static let integrationOpencode = "integrationOpencode"
        static let customProcesses    = "customProcesses"
        static let graceSeconds       = "graceSeconds"
        static let pollSeconds        = "pollSeconds"
    }

    private init() {
        store.register(defaults: [
            Key.keepDisplayOn: false,
            Key.allowLidClosed: false,
            Key.integrationClaude: true,
            Key.integrationOmp: true,
            Key.integrationOpencode: true,
            Key.customProcesses: [String](),
            Key.graceSeconds: 90.0,
            Key.pollSeconds: 5.0,
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
}
