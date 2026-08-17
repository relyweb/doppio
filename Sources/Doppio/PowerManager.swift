// SPDX-License-Identifier: Apache-2.0
import Foundation
import IOKit.pwr_mgt

/// Owns the low-level macOS power state:
///
///  1. **IOKit power assertions** — the same reliable mechanism `caffeinate`
///     wraps. `PreventUserIdleSystemSleep` keeps the *system* awake while idle
///     or while the screen is locked. `PreventUserIdleDisplaySleep` optionally
///     keeps the display on too. These never override the critical-battery
///     emergency sleep, so they can't drain the battery.
///
///  2. **Lid-closed (clamshell)** — power assertions do NOT stop the Mac from
///     sleeping with the lid shut; only `pmset disablesleep` does, and that is
///     unsafe to hold on battery. It is delegated entirely to `LidSleepHelper`,
///     a privileged daemon that enforces "AC only" on its own. Here we just
///     publish our desired flag.
final class PowerManager {

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false

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
            LidSleepHelper.shared.setDesired(allowLidClosed)
        } else {
            releaseSystemAssertion()
            releaseDisplayAssertion()
            LidSleepHelper.shared.setDesired(false)
        }
    }

    /// Release everything and restore normal sleep behavior. Call on quit.
    func shutdown() {
        releaseSystemAssertion()
        releaseDisplayAssertion()
        LidSleepHelper.shared.setDesired(false)
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
}
