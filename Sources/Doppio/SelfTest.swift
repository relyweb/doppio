import Foundation

/// Headless verification that the power-assertion machinery works end to end.
/// Acquires a system sleep assertion, confirms it is visible to the OS via
/// `pmset -g assertions`, then releases it and confirms it is gone.
enum SelfTest {
    static func run() {
        let power = PowerManager()
        let reason = "Doppio: selftest"

        print("[selftest] acquiring PreventUserIdleSystemSleep assertion…")
        power.apply(active: true, keepDisplayOn: false, allowLidClosed: false, reason: reason)
        let held = pmsetShowsDoppio()
        print("[selftest] assertion visible to pmset: \(held)")

        power.apply(active: false, keepDisplayOn: false, allowLidClosed: false, reason: reason)
        let releasedGone = !pmsetShowsDoppio()
        print("[selftest] assertion released: \(releasedGone)")

        if held && releasedGone {
            print("[selftest] PASS")
        } else {
            print("[selftest] FAIL (held=\(held), releasedGone=\(releasedGone))")
            exit(1)
        }
    }

    /// Verifies that "Keep Awake Indefinitely" and the timer are mutually
    /// exclusive — the most recent user choice overrides the other.
    static func runModes() {
        let c = AwakeCoordinator()   // not started: no monitor/timer side effects
        func check(_ name: String, _ cond: Bool) {
            print("[modes] \(name): \(cond ? "ok" : "FAIL")")
            if !cond { c.shutdown(); exit(1) }
        }

        c.setTimer(for: 3600)
        check("timer set -> timer active", c.timerActive)
        check("timer set -> manual off", !c.manualIndefinite)

        c.setManualIndefinite(true)
        check("manual on -> manual active", c.manualIndefinite)
        check("manual on -> timer cleared", !c.timerActive)
        check("manual on -> summary excludes timer", !c.reasonSummary.contains("timer"))

        c.setTimer(for: 3600)
        check("timer again -> timer active", c.timerActive)
        check("timer again -> manual cleared", !c.manualIndefinite)

        c.setManualIndefinite(true)    // indefinite overrides the running timer
        check("manual overrides timer again -> timer cleared", !c.timerActive)
        c.setManualIndefinite(false)   // turn the single active mode off
        check("manual off -> nothing active", !c.manualIndefinite && !c.timerActive)

        // Battery policy (pure function).
        check("battery: AC + pause -> active", AwakeCoordinator.effectiveActive(want: true, onAC: true, pauseOnBattery: true))
        check("battery: batt + pause -> suppressed", !AwakeCoordinator.effectiveActive(want: true, onAC: false, pauseOnBattery: true))
        check("battery: batt + no-pause -> active", AwakeCoordinator.effectiveActive(want: true, onAC: false, pauseOnBattery: false))

        // Signal tokens: live PID kept, dead+stale token cleaned.
        Runtime.ensureDirectory(Runtime.activeDirectory)
        let liveToken = Runtime.activeDirectory.appendingPathComponent("selftest-live")
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: liveToken, atomically: true, encoding: .utf8)
        let deadToken = Runtime.activeDirectory.appendingPathComponent("selftest-dead")
        try? "999999".write(to: deadToken, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: deadToken.path)
        let signals = ActivityMonitor.liveSignals()
        check("signal: live PID token detected", signals.contains("selftest-live"))
        check("signal: dead+stale token cleaned", !FileManager.default.fileExists(atPath: deadToken.path))
        try? FileManager.default.removeItem(at: liveToken)

        // Schedule window (pure, deterministic calendar).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func day(_ d: Int, _ h: Int, _ m: Int) -> Date {   // Jan 2024: 1=Mon … 7=Sun
            cal.date(from: DateComponents(year: 2024, month: 1, day: d, hour: h, minute: m))!
        }
        let week: Set<Int> = [2, 3, 4, 5, 6]  // Mon–Fri
        check("schedule: Mon 10:00 in 9–18", Schedule.isActive(date: day(1, 10, 0), startMinutes: 540, endMinutes: 1080, weekdays: week, calendar: cal))
        check("schedule: Mon 20:00 outside", !Schedule.isActive(date: day(1, 20, 0), startMinutes: 540, endMinutes: 1080, weekdays: week, calendar: cal))
        check("schedule: Sun 10:00 excluded", !Schedule.isActive(date: day(7, 10, 0), startMinutes: 540, endMinutes: 1080, weekdays: week, calendar: cal))
        // Overnight 22:00–06:00 on Mon.
        check("schedule: Mon 23:00 overnight", Schedule.isActive(date: day(1, 23, 0), startMinutes: 1320, endMinutes: 360, weekdays: [2], calendar: cal))
        check("schedule: Tue 05:00 carryover", Schedule.isActive(date: day(2, 5, 0), startMinutes: 1320, endMinutes: 360, weekdays: [2], calendar: cal))
        check("schedule: Tue 07:00 ended", !Schedule.isActive(date: day(2, 7, 0), startMinutes: 1320, endMinutes: 360, weekdays: [2], calendar: cal))
        check("schedule: Wed 05:00 no carryover", !Schedule.isActive(date: day(3, 5, 0), startMinutes: 1320, endMinutes: 360, weekdays: [2], calendar: cal))

        // Watch-until-exit: live PID keeps active, dead PID pruned on add.
        c.watch(pid: ProcessInfo.processInfo.processIdentifier, name: "self")
        check("watch: live pid active", c.watchActive)
        c.watch(pid: 999999, name: "dead")
        check("watch: dead pid pruned", !c.watched.keys.contains(999999))
        c.clearWatches()
        check("watch: cleared -> inactive", !c.watchActive)

        c.shutdown()
        print("[modes] PASS")
    }

    /// Prints a diagnostic snapshot of power source, live signal tokens, and
    /// the current battery policy — handy for support and manual testing.
    static func runDiag() {
        let ps = PowerSource.current()
        print("power source : \(ps.onAC ? "AC" : "battery")\(ps.percent.map { " (\($0)%)" } ?? "")")
        print("pause-on-batt: \(Preferences.shared.pauseOnBattery)")
        print("lid-closed   : \(Preferences.shared.allowLidClosed) (effective only on AC)")
        let signals = ActivityMonitor.liveSignals()
        print("live signals : \(signals.isEmpty ? "(none)" : signals.joined(separator: ", ")) in \(Runtime.activeDirectory.path)")
    }

    /// True if `pmset -g assertions` lists an assertion whose name mentions Doppio.
    private static func pmsetShowsDoppio() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g", "assertions"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("Doppio")
        } catch {
            return false
        }
    }
}
