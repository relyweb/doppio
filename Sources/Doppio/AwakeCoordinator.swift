import Foundation

/// Central brain. Combines three independent reasons the Mac should stay awake
/// and reconciles them into a single power state on every tick:
///
///   * **Manual** — user flipped "Keep Awake Indefinitely".
///   * **Timer**  — user asked to stay awake until a specific moment.
///   * **Activity** — an enabled integration (claude/omp/opencode/custom) is
///     running, optionally extended by a grace period after it exits.
final class AwakeCoordinator {

    private let power = PowerManager()
    private let monitor = ActivityMonitor()
    private let prefs = Preferences.shared

    /// Called on the main thread whenever the derived state changes.
    var onStateChange: (() -> Void)?

    // Runtime state (never persisted).
    private(set) var manualIndefinite = false
    private(set) var timerUntil: Date?
    private var activity = ActivitySnapshot()
    private var lastActivitySeen: Date?

    // A steady tick so timer expiry and grace-period expiry are honored even
    // when the process table hasn't changed.
    private var tick: DispatchSourceTimer?

    // MARK: - Lifecycle

    func start() {
        reconfigureMonitor()
        monitor.onUpdate = { [weak self] snap in
            guard let self else { return }
            self.activity = snap
            if snap.anyActive { self.lastActivitySeen = Date() }
            self.recompute()
        }
        monitor.start(interval: prefs.pollSeconds)

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.recompute() }
        tick = t
        t.resume()

        recompute()
    }

    func shutdown() {
        tick?.cancel(); tick = nil
        monitor.stop()
        power.shutdown()
    }

    // MARK: - Derived state

    /// Grace-extended activity: true while a process runs and for
    /// `graceSeconds` after the last one disappears.
    var activityActive: Bool {
        if activity.anyActive { return true }
        if let last = lastActivitySeen {
            return Date().timeIntervalSince(last) < prefs.graceSeconds
        }
        return false
    }

    var timerActive: Bool {
        guard let until = timerUntil else { return false }
        return until > Date()
    }

    var isActive: Bool { manualIndefinite || timerActive || activityActive }

    /// Human-readable explanation for the menu and the assertion name.
    var reasonSummary: String {
        var parts: [String] = []
        if manualIndefinite { parts.append("manual") }
        if timerActive, let until = timerUntil {
            parts.append("timer until \(Self.timeFormatter.string(from: until))")
        }
        if activity.anyActive {
            parts.append("running: " + activity.activeLabels.joined(separator: ", "))
        } else if activityActive {
            parts.append("grace period")
        }
        return parts.isEmpty ? "idle" : parts.joined(separator: " · ")
    }

    var currentSnapshot: ActivitySnapshot { activity }

    // MARK: - User actions

    func setManualIndefinite(_ on: Bool) {
        manualIndefinite = on
        recompute()
    }

    /// Keep awake for a relative duration from now.
    func setTimer(for duration: TimeInterval) {
        timerUntil = Date().addingTimeInterval(duration)
        recompute()
    }

    /// Keep awake until an absolute wall-clock moment (already resolved to a
    /// future Date by the caller).
    func setTimer(until date: Date) {
        timerUntil = date
        recompute()
    }

    func clearTimer() {
        timerUntil = nil
        recompute()
    }

    /// Re-read integration/custom-process settings and repoll immediately.
    func reconfigureMonitor() {
        monitor.configure(
            claude: prefs.integrationClaude,
            omp: prefs.integrationOmp,
            opencode: prefs.integrationOpencode,
            custom: prefs.customProcesses)
        monitor.pollNow()
    }

    /// Re-apply power state after an option (display/lid) changed.
    func optionsChanged() { recompute() }

    // MARK: - Core reconcile

    private func recompute() {
        // Expire the timer once its moment passes.
        if let until = timerUntil, until <= Date() {
            timerUntil = nil
        }
        power.apply(
            active: isActive,
            keepDisplayOn: prefs.keepDisplayOn,
            allowLidClosed: prefs.allowLidClosed,
            reason: "Doppio: \(reasonSummary)")
        onStateChange?()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
