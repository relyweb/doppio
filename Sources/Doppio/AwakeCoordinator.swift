// SPDX-License-Identifier: Apache-2.0
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
    private(set) var lastPowerSource: PowerSource.State?

    /// Semantic events for the UI layer to surface (notifications).
    enum Event: Equatable { case timerExpired, watchEnded(String), scheduleEnded }
    var onEvent: ((Event) -> Void)?

    /// Processes to keep awake until they exit (pid -> display name).
    private(set) var watched: [Int32: String] = [:]
    private var lastScheduleActive = false

    // A steady tick so timer expiry and grace-period expiry are honored even
    // when the process table hasn't changed.
    private var tick: DispatchSourceTimer?

    // MARK: - Lifecycle

    func start() {
        // Clean up any pre-daemon state, then install/remove the privileged lid
        // helper to match the setting. If a needed install is cancelled at
        // launch, don't keep claiming the feature is on.
        LidSleepHelper.shared.migrateLegacyState()
        if !LidSleepHelper.shared.setEnabled(prefs.allowLidClosed), prefs.allowLidClosed {
            prefs.allowLidClosed = false
        }
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

    /// Seconds left on the timer, or nil when no timer is running. Used to show
    /// a live countdown in the menu bar (only meaningful in timer mode).
    var timeRemaining: TimeInterval? {
        guard let until = timerUntil, until > Date() else { return nil }
        return until.timeIntervalSinceNow
    }
    var watchActive: Bool { !watched.isEmpty }

    /// Inside the recurring weekly window (feature: Schedule).
    var scheduleActive: Bool {
        guard prefs.scheduleEnabled else { return false }
        return Schedule.isActive(date: Date(),
                                 startMinutes: prefs.scheduleStartMinutes,
                                 endMinutes: prefs.scheduleEndMinutes,
                                 weekdays: Set(prefs.scheduleWeekdays))
    }

    var wantActive: Bool {
        manualIndefinite || timerActive || activityActive || watchActive || scheduleActive
    }

    /// Sources the user turned on deliberately — honored even on low battery
    /// (down to the hard safety floor).
    var explicitWant: Bool { manualIndefinite || timerActive }

    /// Sources that fire on their own — yielded to the soft battery floor.
    var automaticWant: Bool { activityActive || watchActive || scheduleActive }

    /// Below this charge the Mac is always allowed to sleep, even for explicit
    /// keep-awake, so a task can never drain the battery to death.
    static let hardBatteryFloor = 20

    /// Effective keep-awake state (what we actually assert) after the battery
    /// policy is applied.
    var isActive: Bool {
        Self.effectiveActive(explicitWant: explicitWant,
                             automaticWant: automaticWant,
                             onAC: lastPowerSource?.onAC ?? true,
                             percent: lastPowerSource?.percent,
                             pauseOnBattery: prefs.pauseOnBattery,
                             batteryFloor: prefs.batteryFloorPercent,
                             hardFloor: Self.hardBatteryFloor)
    }

    /// True when we *want* to stay awake but the battery policy is holding back.
    var batterySuppressed: Bool { wantActive && !isActive }
    var onBattery: Bool { !(lastPowerSource?.onAC ?? true) }
    var batteryPercent: Int? { lastPowerSource?.percent }

    /// Human-readable explanation for the menu and the assertion name.
    var reasonSummary: String {
        var parts: [String] = []
        if manualIndefinite { parts.append("manual") }
        if timerActive, let until = timerUntil {
            parts.append("timer until \(Self.timeFormatter.string(from: until))")
        }
        if activity.anyProcessRunning {
            parts.append("running: " + activity.runningLabels.joined(separator: ", "))
        }
        if !activity.signals.isEmpty {
            parts.append("signal (\(activity.signals.count))")
        }
        if watchActive {
            parts.append("waiting on " + watched.values.sorted().joined(separator: ", "))
        }
        if scheduleActive { parts.append("schedule") }
        if parts.isEmpty && activityActive { parts.append("grace period") }
        return parts.isEmpty ? "idle" : parts.joined(separator: " · ")
    }

    var currentSnapshot: ActivitySnapshot { activity }

    // MARK: - User actions
    //
    // "Keep Awake Indefinitely" and the timer are two mutually exclusive
    // user-chosen modes: the most recent choice wins, so the menu never shows
    // both at once. (Integration/activity keep-awake is separate and automatic.)

    func setManualIndefinite(_ on: Bool) {
        manualIndefinite = on
        if on { timerUntil = nil }   // indefinite overrides any running timer
        recompute()
    }

    /// Keep awake for a relative duration from now.
    func setTimer(for duration: TimeInterval) {
        timerUntil = Date().addingTimeInterval(duration)
        manualIndefinite = false     // a timer overrides indefinite mode
        recompute()
    }

    /// Keep awake until an absolute wall-clock moment (already resolved to a
    /// future Date by the caller).
    func setTimer(until date: Date) {
        timerUntil = date
        manualIndefinite = false     // a timer overrides indefinite mode
        recompute()
    }

    func clearTimer() {
        timerUntil = nil
        recompute()
    }

    /// Keep awake until a specific process exits.
    func watch(pid: Int32, name: String) {
        watched[pid] = name
        recompute()
    }
    func unwatch(pid: Int32) {
        watched[pid] = nil
        recompute()
    }
    func clearWatches() {
        watched.removeAll()
        recompute()
    }

    /// Re-read integration/custom-process settings and repoll immediately.
    func reconfigureMonitor() {
        monitor.configure(
            claude: prefs.integrationClaude,
            omp: prefs.integrationOmp,
            opencode: prefs.integrationOpencode,
            codex: prefs.integrationCodex,
            gemini: prefs.integrationGemini,
            custom: prefs.customProcesses)
        monitor.pollNow()
    }

    /// Restart the activity monitor to pick up a new poll interval.
    func restartMonitor() {
        monitor.start(interval: prefs.pollSeconds)
    }

    /// Re-apply power state after an option (display/schedule) changed.
    func optionsChanged() { recompute() }

    /// The "Allow When Lid Closed" setting changed: install or remove the
    /// privileged helper to match, then re-apply. Returns false if the admin
    /// prompt was cancelled, so the UI can revert the toggle.
    @discardableResult
    func lidClosedSettingChanged() -> Bool {
        let ok = LidSleepHelper.shared.setEnabled(prefs.allowLidClosed)
        recompute()
        return ok
    }

    // MARK: - Core reconcile

    private func recompute() {
        // Expire the timer once its moment passes.
        if let until = timerUntil, until <= Date() {
            timerUntil = nil
            onEvent?(.timerExpired)
        }
        // Drop watched processes that have exited (fire once each).
        for (pid, name) in watched where kill(pid, 0) != 0 {
            watched[pid] = nil
            onEvent?(.watchEnded(name))
        }
        // Notify when a scheduled window closes (edge-triggered).
        let scheduleNow = scheduleActive
        if lastScheduleActive && !scheduleNow { onEvent?(.scheduleEnded) }
        lastScheduleActive = scheduleNow

        lastPowerSource = PowerSource.current()

        power.apply(
            active: isActive,
            keepDisplayOn: prefs.keepDisplayOn,
            // Lid-closed is delegated to LidSleepHelper's privileged daemon,
            // which enforces the "AC only" rule autonomously (see that file).
            // We publish pure intent; the daemon forces sleep back on when on
            // battery, so an unattended unplug can never deep-discharge the Mac.
            allowLidClosed: prefs.allowLidClosed,
            reason: "Doppio: \(reasonSummary)")
        onStateChange?()
    }

    /// Pure battery policy (testable). On AC / unknown charge / with the pause
    /// disabled, any request keeps the Mac awake. On battery with the pause on:
    ///   • below the hard floor  → sleep allowed (even explicit intent);
    ///   • below the soft floor  → only *explicit* intent (manual/timer) wins;
    ///   • at or above the floor → any request keeps it awake.
    static func effectiveActive(explicitWant: Bool, automaticWant: Bool,
                                onAC: Bool, percent: Int?,
                                pauseOnBattery: Bool, batteryFloor: Int,
                                hardFloor: Int) -> Bool {
        let anyWant = explicitWant || automaticWant
        guard pauseOnBattery, !onAC, let percent else { return anyWant }
        if percent < hardFloor { return false }
        if percent < batteryFloor { return explicitWant }
        return anyWant
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
