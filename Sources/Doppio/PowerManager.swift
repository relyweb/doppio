import Foundation
import IOKit.pwr_mgt

/// Owns the low-level macOS power state:
///
///  1. **IOKit power assertions** — the same reliable mechanism `caffeinate`
///     wraps. `PreventUserIdleSystemSleep` keeps the *system* awake while idle
///     or while the screen is locked. `PreventUserIdleDisplaySleep` optionally
///     keeps the display on too.
///
///  2. **`pmset disablesleep`** — power assertions do NOT stop the Mac from
///     sleeping when the lid is closed (clamshell). Only disabling sleep at the
///     pmset level does. That requires root, so it is applied through a single
///     admin-authorized `osascript` call and always reverted when we go idle
///     or quit.
final class PowerManager {

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false
    private(set) var lidSleepDisabled = false

    /// True if we currently hold any keep-awake assertion.
    var isHoldingAssertion: Bool { hasSystemAssertion || hasDisplayAssertion }

    // MARK: - Public entry point

    /// Reconcile the actual power state with the desired one. Idempotent: safe
    /// to call on every state recompute; only real transitions do any work.
    func apply(active: Bool, keepDisplayOn: Bool, allowLidClosed: Bool, reason: String) {
        if active {
            ensureSystemAssertion(reason: reason)
            if keepDisplayOn { ensureDisplayAssertion(reason: reason) }
            else { releaseDisplayAssertion() }
            setLidSleepDisabled(active && allowLidClosed)
        } else {
            releaseSystemAssertion()
            releaseDisplayAssertion()
            setLidSleepDisabled(false)
        }
    }

    /// Release everything and restore normal sleep behavior. Call on quit.
    func shutdown() {
        releaseSystemAssertion()
        releaseDisplayAssertion()
        setLidSleepDisabled(false)
    }

    // MARK: - System assertion

    private func ensureSystemAssertion(reason: String) {
        guard !hasSystemAssertion else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        if r == kIOReturnSuccess {
            systemAssertion = id
            hasSystemAssertion = true
        } else {
            NSLog("Doppio: failed to create system sleep assertion (0x%08x)", r)
        }
    }

    private func releaseSystemAssertion() {
        guard hasSystemAssertion else { return }
        IOPMAssertionRelease(systemAssertion)
        systemAssertion = 0
        hasSystemAssertion = false
    }

    // MARK: - Display assertion

    private func ensureDisplayAssertion(reason: String) {
        guard !hasDisplayAssertion else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        if r == kIOReturnSuccess {
            displayAssertion = id
            hasDisplayAssertion = true
        } else {
            NSLog("Doppio: failed to create display sleep assertion (0x%08x)", r)
        }
    }

    private func releaseDisplayAssertion() {
        guard hasDisplayAssertion else { return }
        IOPMAssertionRelease(displayAssertion)
        displayAssertion = 0
        hasDisplayAssertion = false
    }

    // MARK: - Lid-closed (pmset disablesleep)

    private func setLidSleepDisabled(_ disabled: Bool) {
        guard disabled != lidSleepDisabled else { return }
        let value = disabled ? "1" : "0"
        // `-a` applies to all power sources so the setting holds on battery too.
        let ok = runPrivileged("/usr/bin/pmset -a disablesleep \(value)")
        if ok {
            lidSleepDisabled = disabled
            // Sentinel lets a crashed process restore normal sleep next launch.
            if disabled { writeSentinel() } else { removeSentinel() }
        } else {
            NSLog("Doppio: pmset disablesleep %@ was cancelled or failed", value)
        }
    }

    /// If a previous run set `disablesleep` and died without reverting, restore
    /// it. Only prompts for admin when sleep is *actually* still disabled
    /// (a reboot already clears it), so the common case is silent.
    func recoverFromCrashIfNeeded() {
        guard FileManager.default.fileExists(atPath: Runtime.lidSentinel.path) else { return }
        if isSystemSleepDisabled() {
            NSLog("Doppio: recovering from crash — restoring pmset disablesleep 0")
            if runPrivileged("/usr/bin/pmset -a disablesleep 0") {
                removeSentinel()
            }
        } else {
            removeSentinel()   // stale sentinel (e.g. after reboot); just clean up
        }
    }

    private func writeSentinel() {
        Runtime.ensureDirectory(Runtime.directory)
        try? Data().write(to: Runtime.lidSentinel)
    }

    private func removeSentinel() {
        try? FileManager.default.removeItem(at: Runtime.lidSentinel)
    }

    /// True if `pmset -g` currently reports sleep as disabled.
    private func isSystemSleepDisabled() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            // pmset prints "SleepDisabled  1" only when it is on.
            return text.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
        } catch {
            return false
        }
    }

    /// Run a shell command as root via a single admin-authorization prompt.
    /// Returns false if the user cancelled the authorization dialog.
    @discardableResult
    private func runPrivileged(_ command: String) -> Bool {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            NSLog("Doppio: failed to launch osascript: %@", error.localizedDescription)
            return false
        }
    }
}
