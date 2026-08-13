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

        // Battery policy: explicit intent honored to the hard floor; automatic
        // sources yield to the soft floor. eff(explicit, auto, onAC, pct, pause, floor)
        func eff(_ ex: Bool, _ au: Bool, _ onAC: Bool, _ pct: Int?, _ pause: Bool, _ floor: Int) -> Bool {
            AwakeCoordinator.effectiveActive(explicitWant: ex, automaticWant: au, onAC: onAC,
                                             percent: pct, pauseOnBattery: pause, batteryFloor: floor,
                                             hardFloor: 15)
        }
        check("battery: AC always active", eff(false, true, true, 10, true, 30))
        check("battery: pause off -> active", eff(false, true, false, 5, false, 30))
        check("battery: unknown pct -> active", eff(false, true, false, nil, true, 30))
        check("battery: automatic vetoed below soft floor", !eff(false, true, false, 20, true, 30))
        check("battery: explicit honored below soft floor", eff(true, false, false, 20, true, 30))
        check("battery: hard floor vetoes even explicit", !eff(true, false, false, 10, true, 30))
        check("battery: above soft floor -> any active", eff(false, true, false, 50, true, 30))

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
        print("pause-on-batt: \(Preferences.shared.pauseOnBattery) (automatic below \(Preferences.shared.batteryFloorPercent)%, all below \(AwakeCoordinator.hardBatteryFloor)%)")
        print("lid-closed   : \(Preferences.shared.allowLidClosed) (effective only on AC)")
        let signals = ActivityMonitor.liveSignals()
        print("live signals : \(signals.isEmpty ? "(none)" : signals.joined(separator: ", ")) in \(Runtime.activeDirectory.path)")
    }

    /// Integration test: confirm `PowerSource.current()` fetches a real power
    /// state and (on a laptop) a known battery percentage, cross-checked against
    /// `pmset -g batt`. Fails if the charge is unknown while a battery exists,
    /// or if AC/percent disagree with pmset.
    static func runPower() {
        let ps = PowerSource.current()
        print("[power] PowerSource: onAC=\(ps.onAC) percent=\(ps.percent.map { "\($0)%" } ?? "unknown")")

        let batt = capture("/usr/bin/pmset", ["-g", "batt"])
        print("[power] pmset -g batt: \(batt.trimmingCharacters(in: .whitespacesAndNewlines))")

        let pmsetAC = batt.contains("'AC Power'")
        var pmsetPct: Int?
        if let r = batt.range(of: #"\d+%"#, options: .regularExpression) {
            pmsetPct = Int(batt[r].dropLast())
        }
        let hasBattery = batt.contains("InternalBattery") || pmsetPct != nil

        var ok = true
        if ps.onAC == pmsetAC {
            print("[power] onAC matches pmset: \(ps.onAC)")
        } else {
            print("[power] FAIL onAC mismatch (PowerSource=\(ps.onAC), pmset=\(pmsetAC))"); ok = false
        }

        if hasBattery {
            if let p = ps.percent, let q = pmsetPct, abs(p - q) <= 2 {
                print("[power] percent matches pmset (±2): \(p)% vs \(q)%")
            } else {
                print("[power] FAIL battery present but percent unknown/mismatched " +
                      "(PowerSource=\(ps.percent.map { "\($0)%" } ?? "nil"), pmset=\(pmsetPct.map { "\($0)%" } ?? "nil"))")
                ok = false
            }
        } else {
            print("[power] no battery detected (desktop); percent may be nil — skipping")
        }

        print(ok ? "[power] PASS" : "[power] FAIL")
        if !ok { exit(1) }
    }

    private static func capture(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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
