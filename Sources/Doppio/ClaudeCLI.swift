// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The result of one headless resume attempt (`claude -p --resume …`).
enum ResumeOutcome: Equatable {
    case resumed(String)              // session continued; assistant result text
    case rateLimited(reset: Date?)    // usage limit still active; retry later
    case needsPermission              // continuation needs interactive approval
    case authRequired                 // not signed in / auth or billing problem
    case sessionNotFound              // the session id no longer exists
    case cliMissing                   // the `claude` binary could not be found
    case failed(String)               // any other error (retry a bounded number)
}

/// Minimal reference box so a background drain / watchdog closure can publish a
/// value back to the calling thread. Synchronized after the child exits and the
/// semaphore is signalled, so no additional locking is required here.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Thin wrapper around the Claude Code CLI. Runs a **headless** resume and maps
/// the process result to a `ResumeOutcome`. The classifier is pure (input:
/// exit code + stdout + stderr) so it is unit-testable without spawning `claude`.
///
/// Resuming while still rate-limited is cheap and non-destructive: the request
/// is rejected before a turn runs (no quota spent, no work done), so the engine
/// can safely retry until it succeeds.
enum ClaudeCLI {

    /// Candidate install locations, checked before falling back to `PATH`. The
    /// binary is always invoked by absolute path (never a mutable `PATH`).
    static func resolveBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/opt/claude/bin/claude",
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // Fall back to `which claude` (login PATH may differ from GUI PATH).
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["claude"]
        let out = Pipe(); which.standardOutput = out; which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!path.isEmpty && fm.isExecutableFile(atPath: path)) ? path : nil
    }

    /// Result of running a child process with a watchdog timeout.
    struct Run { let exitCode: Int32; let stdout: String; let stderr: String; let timedOut: Bool }

    /// Run `bin args` in `cwd`, draining stdout/stderr concurrently (reading one
    /// fully before the other can deadlock if the unread pipe fills the child's
    /// buffer), with a watchdog that terminates the child past `timeout`.
    /// Internal (not private) so the self-tests can exercise the timeout/drain
    /// behavior with a stub tool instead of spawning the real `claude`.
    /// Returns nil only if the process could not be launched.
    static func runProcess(bin: String, args: [String], cwd: String?,
                           timeout: TimeInterval) -> Run? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { return nil }

        let errData = Box<Data>(Data())
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData.value = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let timedOut = Box<Bool>(false)
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler { timedOut.value = true; proc.terminate() }
        watchdog.resume()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        errDone.wait()

        return Run(exitCode: proc.terminationStatus,
                   stdout: String(decoding: outData, as: UTF8.self),
                   stderr: String(decoding: errData.value, as: UTF8.self),
                   timedOut: timedOut.value)
    }

    /// Resume `session` headlessly with `message`, returning the classified
    /// outcome. Blocks until the CLI exits (call off the main thread).
    static func resume(_ session: ClaudeSession, message: String,
                       timeout: TimeInterval = 180) -> ResumeOutcome {
        guard let bin = resolveBinary() else { return .cliMissing }
        guard let run = runProcess(
            bin: bin,
            args: ["-p", "--resume", session.id, "--output-format", "json", message],
            cwd: session.cwd, timeout: timeout)
        else { return .failed("launch failed") }
        if run.timedOut { return .failed("resume timed out after \(Int(timeout))s") }
        return classify(exitCode: run.exitCode, stdout: run.stdout, stderr: run.stderr)
    }

    /// Pure classifier over the CLI's `--output-format json` envelope
    /// (`{"is_error":Bool,"result":String,…}`) plus stderr, using text
    /// heuristics for error subtypes. Unknown errors map to `.failed` so the
    /// engine retries a bounded number of times rather than looping forever.
    static func classify(exitCode: Int32, stdout: String, stderr: String) -> ResumeOutcome {
        if let obj = lastJSONObject(in: stdout) {
            let isError = (obj["is_error"] as? Bool) ?? (exitCode != 0)
            let resultText = (obj["result"] as? String) ?? ""
            if !isError { return .resumed(resultText) }
            // Fold any structured error subtype into the text the matcher sees,
            // so a machine-readable `subtype` (if the CLI ever emits one) is
            // honored without depending on it. Falls back to text heuristics.
            let subtype = (obj["subtype"] as? String) ?? (obj["error_type"] as? String) ?? ""
            return classifyError([resultText, subtype, stderr].joined(separator: "\n"))
        }
        // No JSON on stdout.
        if exitCode == 0 { return .resumed(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return classifyError(stdout + "\n" + stderr)
    }

    private static func classifyError(_ text: String) -> ResumeOutcome {
        let t = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { t.contains($0) } }
        // Whole-token match for status codes, so "14290 tokens" is NOT read as a
        // 429 rate-limit (substring matching did that).
        func hasCode(_ code: String) -> Bool {
            t.range(of: "(^|[^0-9])\(code)([^0-9]|$)", options: .regularExpression) != nil
        }

        if hasCode("429") || has("usage limit", "rate limit", "rate_limit",
               "too many requests", "resets at") { return .rateLimited(reset: nil) }
        if has("permission", "not allowed", "requires approval",
               "hasn't granted", "has not granted") { return .needsPermission }
        if has("log in", "please login", "authenticat", "sign in",
               "unauthorized", "credit balance", "invalid api key",
               "api key") { return .authRequired }
        if has("no conversation found", "no such session", "session not found",
               "could not find session", "no session") { return .sessionNotFound }
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(msg.isEmpty ? "unknown error" : String(msg.prefix(200)))
    }

    /// The last top-level JSON object in `s` (the CLI prints one result object;
    /// tolerate leading log lines by scanning for the final `{ … }`).
    private static func lastJSONObject(in s: String) -> [String: Any]? {
        for line in s.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return obj
        }
        return nil
    }
}
