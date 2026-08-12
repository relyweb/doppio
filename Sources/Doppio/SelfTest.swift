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
