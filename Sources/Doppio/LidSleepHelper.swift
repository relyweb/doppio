// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Owns the privileged **lid-closed** mechanism.
///
/// Keeping a Mac awake with the lid shut requires `pmset disablesleep 1`, which
/// is a *global* setting (the pmset `-c`/`-b`/`-a` scope is silently ignored for
/// it — it never appears in `pmset -g custom`) that also defeats macOS's own
/// critical-battery emergency sleep. Setting it directly from Doppio is unsafe:
/// if the Mac goes on battery unattended while it is set, nothing stops the
/// battery from draining to a deep discharge.
///
/// The fix is a tiny **root LaunchDaemon** installed with a single admin prompt.
/// It runs every 10 s and enforces one rule, autonomously and without any
/// further prompts:
///
///   > `disablesleep` is 1 **only** when Doppio's desired flag is a *fresh* "1"
///   > **and** the Mac is on AC power. On battery, with no flag, a stale flag
///   > (Doppio not running), or "0", it forces `disablesleep 0`.
///
/// Because the daemon — not Doppio — flips `disablesleep`, an unattended
/// AC→battery transition (charger slips out, power blip, unplug-and-bag) is
/// handled with no prompt: within one tick the daemon restores normal sleep.
final class LidSleepHelper {

    static let shared = LidSleepHelper()
    private init() {}

    // MARK: - Well-known locations (root-owned; not user-writable)

    static let label = "com.doppio.keepawake.lidhelper"
    static let supportDir = "/Library/Application Support/Doppio"
    static let scriptPath = supportDir + "/lid-helper.sh"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    /// Heartbeat freshness window (seconds). Doppio rewrites the desired flag on
    /// every tick while active; if it stops (crash/quit) the daemon treats the
    /// flag as stale and clears `disablesleep`. Battery safety does NOT depend on
    /// this — the daemon forces 0 on battery regardless — so the window is
    /// generous to avoid nuisance clamshell sleeps on AC.
    static let freshSeconds = 300

    // MARK: - Desired-state channel (no prompt)

    private var lastDesired: Bool?

    /// Tell the daemon whether Doppio wants sleep disabled. Rewrites the flag on
    /// every "true" call so its mtime acts as a liveness heartbeat; when false,
    /// writes only on change. Cheap (a 1-byte atomic write) and never prompts.
    func setDesired(_ on: Bool) {
        if !on && lastDesired == false { return }
        lastDesired = on
        Runtime.ensureDirectory(Runtime.directory)
        try? (on ? "1" : "0").write(to: Runtime.desiredFile,
                                    atomically: true, encoding: .utf8)
    }

    // MARK: - Pure safety rule (shared spec, exercised by SelfTest)

    /// The single rule the shell daemon implements. Kept here so it is unit
    /// testable and documented in one place.
    static func shouldDisableSleep(desired: Bool, heartbeatFresh: Bool,
                                   onAC: Bool) -> Bool {
        desired && heartbeatFresh && onAC
    }

    // MARK: - Install / uninstall

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.plistPath)
    }

    /// True when the daemon is missing or its script is out of date and must be
    /// (re)installed to match this build.
    func needsInstall() -> Bool {
        guard isInstalled else { return true }
        guard let onDisk = try? String(contentsOfFile: Self.scriptPath,
                                       encoding: .utf8) else { return true }
        return onDisk != Self.scriptContents()
    }

    /// Reconcile the daemon's installation with `enabled`. Prompts for admin
    /// only on a real install/uninstall transition (never when already in the
    /// desired state). Returns true iff the resulting state matches `enabled` —
    /// false only when the admin prompt was cancelled or failed, so the caller
    /// can revert the user-facing setting to reflect reality.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled { return needsInstall() ? install() : true }
        return isInstalled ? uninstall() : true
    }

    /// Install (or refresh) the daemon with a single admin prompt. Returns false
    /// if the user cancelled.
    ///
    /// SECURITY: the script and plist contents are base64-encoded in memory and
    /// decoded to their final root-owned locations *by the privileged shell
    /// itself*. Nothing is ever staged in a user-writable path, so a same-user
    /// process cannot substitute the bytes root installs (no TOCTOU). base64
    /// uses only `[A-Za-z0-9+/=]`, none of which are shell- or AppleScript-
    /// special, so the payload can't break out of the command string either.
    @discardableResult
    func install() -> Bool {
        let scriptB64 = Data(Self.scriptContents().utf8).base64EncodedString()
        let plistB64 = Data(Self.plistContents().utf8).base64EncodedString()

        let cmd = [
            // Own the support directory as root, mode 0755, so its contents can
            // only be replaced by root (defends the script from tampering).
            "/bin/mkdir -p '\(Self.supportDir)'",
            "/usr/sbin/chown root:wheel '\(Self.supportDir)'",
            "/bin/chmod 755 '\(Self.supportDir)'",
            // Root writes the files itself from the inline payloads.
            "/bin/echo '\(scriptB64)' | /usr/bin/base64 -D > '\(Self.scriptPath)'",
            "/usr/sbin/chown root:wheel '\(Self.scriptPath)'",
            "/bin/chmod 644 '\(Self.scriptPath)'",
            "/bin/echo '\(plistB64)' | /usr/bin/base64 -D > '\(Self.plistPath)'",
            "/usr/sbin/chown root:wheel '\(Self.plistPath)'",
            "/bin/chmod 644 '\(Self.plistPath)'",
            "(/bin/launchctl bootout system '\(Self.plistPath)' 2>/dev/null || true)",
            "/bin/launchctl bootstrap system '\(Self.plistPath)'",
        ].joined(separator: " && ")

        let ok = runPrivileged(cmd, prompt:
            "Doppio needs to install a small helper so it can safely keep the Mac awake with the lid closed. The helper only ever runs on AC power and always restores normal sleep on battery.")
        if !ok { NSLog("Doppio: lid helper install cancelled or failed") }
        return ok
    }

    /// Remove the daemon and restore normal sleep, with a single admin prompt.
    @discardableResult
    func uninstall() -> Bool {
        let cmd = [
            "(/bin/launchctl bootout system '\(Self.plistPath)' 2>/dev/null || true)",
            "/bin/rm -f '\(Self.plistPath)'",
            "/bin/rm -f '\(Self.scriptPath)'",
            "/usr/bin/pmset -a disablesleep 0",
        ].joined(separator: "; ")
        let ok = runPrivileged(cmd, prompt:
            "Doppio is removing its lid-closed helper and restoring normal sleep.")
        if !ok { NSLog("Doppio: lid helper uninstall cancelled or failed") }
        return ok
    }

    // MARK: - Legacy migration (pre-daemon builds set disablesleep directly)

    /// Older builds set `pmset disablesleep` from Doppio itself and left a
    /// sentinel. If that sentinel is present, clear any lingering global
    /// `disablesleep 1` once and remove the sentinel so this never runs again.
    func migrateLegacyState() {
        let sentinel = Runtime.lidSentinel
        guard FileManager.default.fileExists(atPath: sentinel.path) else { return }
        if isSleepDisabled() {
            NSLog("Doppio: migrating — clearing legacy pmset disablesleep")
            _ = runPrivileged("/usr/bin/pmset -a disablesleep 0", prompt:
                "Doppio is restoring normal sleep left over from a previous version.")
        }
        try? FileManager.default.removeItem(at: sentinel)
    }

    /// True if the live `pmset -g` output reports `SleepDisabled 1` (a global
    /// setting reported under "System-wide power settings").
    private func isSleepDisabled() -> Bool {
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
            return text.range(of: #"SleepDisabled\s+1"#,
                              options: .regularExpression) != nil
        } catch {
            return false
        }
    }

    // MARK: - Generated helper contents

    /// The root daemon. Self-contained POSIX sh (no dependency on Doppio), so it
    /// keeps enforcing battery safety even if Doppio is not running.
    static func scriptContents() -> String {
        // Single-quote-escape the path so an unusual home directory containing a
        // quote can't break out of the sh string literal below.
        let desired = Runtime.desiredFile.path.replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/sh
        # Doppio lid-closed helper — root LaunchDaemon (\(label)).
        #
        # SINGLE SAFETY RULE: pmset disablesleep is set to 1 ONLY when Doppio's
        # desired flag is a fresh "1" AND the Mac is on AC power. In EVERY other
        # case — on battery, no flag, a stale flag (Doppio not running), or "0" —
        # it forces disablesleep 0, so a lid-closed task can NEVER drain the
        # battery to a deep discharge.
        DESIRED_FILE='\(desired)'
        FRESH=\(freshSeconds)

        target=0
        if [ -r "$DESIRED_FILE" ]; then
          val=$(/bin/cat "$DESIRED_FILE" 2>/dev/null)
          mtime=$(/usr/bin/stat -f %m "$DESIRED_FILE" 2>/dev/null || echo 0)
          now=$(/bin/date +%s)
          age=$((now - mtime))
          if [ "$val" = "1" ] && [ "$age" -le "$FRESH" ] && \\
             /usr/bin/pmset -g ps | /usr/bin/grep -q "'AC Power'"; then
            target=1
          fi
        fi

        current=0
        if /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1'; then
          current=1
        fi

        if [ "$current" != "$target" ]; then
          /usr/bin/pmset -a disablesleep "$target"
        fi
        """
    }

    static func plistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/sh</string>
            <string>\(scriptPath)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>StartInterval</key><integer>10</integer>
          <key>ProcessType</key><string>Background</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Privileged execution

    /// Run a command as root via one admin-authorization prompt. Returns false
    /// if the user cancelled the dialog.
    @discardableResult
    private func runPrivileged(_ command: String, prompt: String) -> Bool {
        let script = "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardError = Pipe()
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
