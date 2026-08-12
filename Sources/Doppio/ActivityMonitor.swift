import Foundation

/// The result of one scan of the process table.
struct ActivitySnapshot: Equatable {
    /// tool label -> whether a matching process is currently running
    var hits: [String: Bool] = [:]

    var anyActive: Bool { hits.values.contains(true) }
    var activeLabels: [String] { hits.filter { $0.value }.map { $0.key }.sorted() }
}

/// Polls the process table and reports which enabled agentic tools are running.
///
/// Detection is deliberately *presence-based*, not CPU-based: an agent waiting
/// on a long model response uses ~0% CPU yet the task is very much in progress —
/// exactly when the Mac must not sleep. As long as the CLI process exists, the
/// tool is considered active. A grace period (applied by the coordinator) keeps
/// the Mac awake briefly after the process exits.
final class ActivityMonitor {

    /// A named matcher against the full process command line. `exclude`, when
    /// present, vetoes an otherwise-matching line (used to ignore persistent
    /// background helpers such as the Claude Code daemon).
    struct Matcher {
        let label: String
        let include: NSRegularExpression
        let exclude: NSRegularExpression?
    }

    var onUpdate: ((ActivitySnapshot) -> Void)?

    private var matchers: [Matcher] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.doppio.activity")

    // MARK: - Configuration

    /// Rebuild the matcher set from the current preferences/toggles.
    func configure(claude: Bool, omp: Bool, opencode: Bool, custom: [String]) {
        var result: [Matcher] = []
        // A tool may be a native binary (`claude`) or launched via a runtime
        // (`node .../claude/cli.js`); the token regex handles both.
        //
        // Claude Code 2.x keeps persistent background daemons alive
        // (`claude daemon run`, `claude bg-pty-host`, `claude bg-spare`) that
        // are NOT interactive sessions — excluding them prevents the Mac from
        // being pinned awake forever whenever Claude Code is merely installed.
        if claude, let m = Self.makeMatcher(
            label: "Claude Code", token: "claude",
            excludeSubcommands: ["daemon", "bg-pty-host", "bg-spare", "bg-spawn"]) {
            result.append(m)
        }
        if omp, let m = Self.makeMatcher(label: "omp", token: "omp") {
            result.append(m)
        }
        if opencode, let m = Self.makeMatcher(label: "opencode", token: "opencode") {
            result.append(m)
        }
        for c in custom {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let m = Self.makeMatcher(label: trimmed, token: trimmed) {
                result.append(m)
            }
        }
        matchers = result
    }

    /// Build a matcher that fires when a command line contains the token as a
    /// whole path component or bare word: `claude`, `/usr/local/bin/claude`,
    /// `node /x/claude foo` — but not `claude-helper` or `claude.js`.
    ///
    /// `excludeSubcommands` vetoes lines like `claude daemon run` so persistent
    /// background processes never count as active work.
    private static func makeMatcher(label: String, token: String,
                                    excludeSubcommands: [String] = []) -> Matcher? {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let includePattern = "(^|/)\(escaped)($|[[:space:]])"
        guard let include = try? NSRegularExpression(pattern: includePattern) else { return nil }
        var exclude: NSRegularExpression?
        if !excludeSubcommands.isEmpty {
            let subs = excludeSubcommands
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            let excludePattern = "(^|/)\(escaped)[[:space:]]+(\(subs))"
            exclude = try? NSRegularExpression(pattern: excludePattern)
        }
        return Matcher(label: label, include: include, exclude: exclude)
    }

    // MARK: - Lifecycle

    func start(interval: TimeInterval) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.scan() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Force an immediate scan (e.g. right after the user changes a toggle).
    func pollNow() { queue.async { [weak self] in self?.scan() } }

    // MARK: - Scan

    private func scan() {
        let lines = Self.runningCommandLines()
        var snapshot = ActivitySnapshot()
        for m in matchers { snapshot.hits[m.label] = false }
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for m in matchers where snapshot.hits[m.label] != true {
                guard m.include.firstMatch(in: line, options: [], range: range) != nil else { continue }
                if let ex = m.exclude, ex.firstMatch(in: line, options: [], range: range) != nil { continue }
                snapshot.hits[m.label] = true
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }

    /// Full, untruncated command lines of every process (`ps -axww -o args=`).
    private static func runningCommandLines() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axww", "-o", "args="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return text.split(separator: "\n").map(String.init)
        } catch {
            NSLog("Doppio: ps failed: %@", error.localizedDescription)
            return []
        }
    }
}
