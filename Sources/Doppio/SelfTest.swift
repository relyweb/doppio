// SPDX-License-Identifier: Apache-2.0
import AppKit

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
                                             hardFloor: AwakeCoordinator.hardBatteryFloor)
        }
        let soft = 30, hard = AwakeCoordinator.hardBatteryFloor   // 30 and 20
        check("battery: AC always active", eff(false, true, true, hard - 5, true, soft))
        check("battery: pause off -> active", eff(false, true, false, hard - 10, false, soft))
        check("battery: unknown pct -> active", eff(false, true, false, nil, true, soft))
        check("battery: automatic vetoed below soft floor", !eff(false, true, false, hard + 5, true, soft))
        check("battery: explicit honored below soft floor", eff(true, false, false, hard + 5, true, soft))
        check("battery: hard floor vetoes even explicit", !eff(true, false, false, hard - 5, true, soft))
        check("battery: above soft floor -> any active", eff(false, true, false, soft + 20, true, soft))

        // Lid-closed safety rule (enforced by the privileged LidSleepHelper
        // daemon). disablesleep must be held ONLY when Doppio wants it, its
        // heartbeat is fresh, AND the Mac is on AC — otherwise the battery can
        // deep-discharge.
        func lid(_ want: Bool, _ fresh: Bool, _ ac: Bool) -> Bool {
            LidSleepHelper.shouldDisableSleep(desired: want, heartbeatFresh: fresh, onAC: ac)
        }
        check("lid: want + fresh + AC -> disable", lid(true, true, true))
        check("lid: want + fresh + battery -> NOT", !lid(true, true, false))
        check("lid: want + stale + AC -> NOT", !lid(true, false, true))
        check("lid: idle -> NOT", !lid(false, true, true))
        // The generated daemon script must encode the same guards.
        let script = LidSleepHelper.scriptContents()
        check("lid: script gates on AC power", script.contains("'AC Power'"))
        check("lid: script has freshness window", script.contains("FRESH=\(LidSleepHelper.freshSeconds)"))
        check("lid: script clears sleep otherwise", script.contains("pmset -a disablesleep"))

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

        // Menu header is width-capped so a long multi-reason status can never
        // stretch the whole menu (regression: the menu used to grow very wide).
        MainActor.assumeIsolated {
            let cap = MenuController.headerContentWidth
            let shortHeader = MenuController.statusHeaderItem("Awake — timer until 3:30 PM")
            let longHeader = MenuController.statusHeaderItem(
                "Awake — " + String(repeating: "running: node, python, claude · ", count: 8))
            let ws = shortHeader.view?.frame.width ?? 0
            let wl = longHeader.view?.frame.width ?? 0
            check("menu: header width capped", ws == cap && wl == cap)
        }

        c.shutdown()
        print("[modes] PASS")
    }

    /// Prints a diagnostic snapshot of power source, live signal tokens, and
    /// the current battery policy — handy for support and manual testing.
    static func runDiag() {
        let ps = PowerSource.current()
        print("power source : \(ps.onAC ? "AC" : "battery")\(ps.percent.map { " (\($0)%)" } ?? "")")
        print("pause-on-batt: \(Preferences.shared.pauseOnBattery) (automatic below \(Preferences.shared.batteryFloorPercent)%, all below \(AwakeCoordinator.hardBatteryFloor)%)")
        print("lid-closed   : \(Preferences.shared.allowLidClosed) (helper installed: \(LidSleepHelper.shared.isInstalled); enforced on AC only by \(LidSleepHelper.label))")
        let signals = ActivityMonitor.liveSignals()
        print("live signals : \(signals.isEmpty ? "(none)" : signals.joined(separator: ", ")) in \(Runtime.activeDirectory.path)")
        let cli = ClaudeCLI.resolveBinary().map { "found (\($0))" } ?? "not found"
        print("auto-resume  : \(Preferences.shared.autoResumeEnabled) · watched \(Preferences.shared.autoResumeSessions.count) · discovered \(ClaudeSessionStore.recent().count) recent Claude sessions · claude \(cli)")
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

    /// Auto-resume: pure classifier, backoff, and session parsing.
    static func runResume() {
        func check(_ name: String, _ cond: Bool) {
            print("[resume] \(name): \(cond ? "ok" : "FAIL")")
            if !cond { exit(1) }
        }
        func isFailed(_ o: ResumeOutcome) -> Bool { if case .failed = o { return true }; return false }
        func isResumed(_ o: ResumeOutcome) -> Bool { if case .resumed = o { return true }; return false }

        // Classifier over the real `--output-format json` envelope shape.
        check("classify: success -> resumed",
              ClaudeCLI.classify(exitCode: 0,
                stdout: #"{"is_error":false,"result":"done","session_id":"x"}"#, stderr: "")
                == .resumed("done"))
        check("classify: usage limit -> rateLimited",
              ClaudeCLI.classify(exitCode: 1,
                stdout: #"{"is_error":true,"result":"Claude AI usage limit reached; resets at 4:30pm"}"#,
                stderr: "") == .rateLimited(reset: nil))
        check("classify: permission -> needsPermission",
              ClaudeCLI.classify(exitCode: 1,
                stdout: #"{"is_error":true,"result":"This tool requires approval / permission"}"#,
                stderr: "") == .needsPermission)
        check("classify: auth -> authRequired",
              ClaudeCLI.classify(exitCode: 1,
                stdout: #"{"is_error":true,"result":"Please sign in to continue"}"#,
                stderr: "") == .authRequired)
        check("classify: missing session -> sessionNotFound",
              ClaudeCLI.classify(exitCode: 1,
                stdout: #"{"is_error":true,"result":"No conversation found with that session id"}"#,
                stderr: "") == .sessionNotFound)
        check("classify: unknown error -> failed",
              isFailed(ClaudeCLI.classify(exitCode: 1,
                stdout: #"{"is_error":true,"result":"boom"}"#, stderr: "")))
        check("classify: no JSON, exit 0 -> resumed",
              isResumed(ClaudeCLI.classify(exitCode: 0, stdout: "OK", stderr: "")))
        check("classify: no JSON, limit in stderr -> rateLimited",
              ClaudeCLI.classify(exitCode: 1, stdout: "", stderr: "429 too many requests")
                == .rateLimited(reset: nil))

        // Backoff: attempt 1 == base, then doubling, capped.
        check("backoff: attempt 1 == base", AutoResumer.backoffDelay(attempt: 1, base: 60, cap: 300) == 60)
        check("backoff: attempt 3 doubles", AutoResumer.backoffDelay(attempt: 3, base: 60, cap: 300) == 240)
        check("backoff: capped", AutoResumer.backoffDelay(attempt: 8, base: 60, cap: 300) == 300)

        // Session parsing reads only cwd + filename + mtime.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppio-resume-\(UUID().uuidString).jsonl")
        let rec = #"{"type":"user","cwd":"/Users/x/proj-name","sessionId":"abc","timestamp":"t"}"# + "\n"
        try? rec.write(to: tmp, atomically: true, encoding: .utf8)
        let parsed = ClaudeSessionStore.session(from: tmp)
        check("session: cwd parsed", parsed?.cwd == "/Users/x/proj-name")
        check("session: id is filename stem", parsed?.id == tmp.deletingPathExtension().lastPathComponent)
        check("session: project is cwd basename", parsed?.project == "proj-name")
        try? FileManager.default.removeItem(at: tmp)

        let tok = ClaudeSession(id: "abc", cwd: "/p/q", lastActivity: .distantPast).token
        check("session: token round-trips", ClaudeSession.from(token: tok)?.cwd == "/p/q")

        // Engine: multiple watched sessions are tracked independently and
        // attempted one at a time (serialized), earliest-due first; a resumed
        // session is dropped, a rate-limited one backs off and retries later.
        let ar = AutoResumer()
        var calls: [String] = []
        ar.resumeProvider = { session, _ in
            calls.append(session.id)
            return session.id == "B" ? .resumed("ok") : .rateLimited(reset: nil)
        }
        let a = ClaudeSession(id: "A", cwd: "/p/a", lastActivity: .distantPast)
        let b = ClaudeSession(id: "B", cwd: "/p/b", lastActivity: .distantPast)
        ar.configure(enabled: true, sessions: [a, b], message: "go", pollSeconds: 60)
        check("engine: two sessions tracked", ar.waitingCount == 2)

        let t0 = Date()
        let s1 = ar.stepForTesting(now: t0)
        check("engine: step 1 attempts exactly one", s1 != nil && calls.count == 1)
        let s2 = ar.stepForTesting(now: t0)
        check("engine: step 2 attempts the other (serialized)", s2 != nil && s2 != s1 && calls.count == 2)
        check("engine: resumed B dropped, rate-limited A remains", ar.waitingCount == 1)
        check("engine: A backs off — not due at t0", ar.stepForTesting(now: t0) == nil)
        check("engine: A due again after backoff window", ar.stepForTesting(now: t0.addingTimeInterval(600)) == "A")
        ar.shutdown()
        check("engine: shutdown clears pending", ar.waitingCount == 0)

        print("[resume] PASS")
    }
}
