// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Drives auto-resume of selected Claude Code CLI sessions after a usage-limit
/// reset. For each watched session it retries a **headless** resume on a backoff
/// schedule (a still-limited attempt is a cheap 429 — no quota spent), and while
/// any session is waiting it asks the coordinator to keep the Mac awake so the
/// scheduler survives idle. Attempts are serialized (one CLI at a time).
///
/// Main-thread driven, like `AwakeCoordinator`: the blocking CLI call runs on a
/// background queue and results are delivered back on the main thread.
final class AutoResumer {

    static let shared = AutoResumer()
    init() {}   // `shared` is the app instance; tests construct their own.

    /// Surfaced to the app for notifications.
    enum Event: Equatable {
        case resumed(String)          // project name
        case needsInteraction(String) // project name (tool approval needed)
        case authRequired
        case cliMissing
        case failed(String)           // project name
    }

    /// Called on the main thread when the count of waiting sessions changes
    /// (drives the keep-awake reason + menu status).
    var onWaitingChange: ((Int) -> Void)?
    var onEvent: ((Event) -> Void)?

    /// Performs one resume. Overridable so tests can drive the scheduler with
    /// stubbed outcomes instead of invoking the real CLI.
    var resumeProvider: (ClaudeSession, String) -> ResumeOutcome = {
        ClaudeCLI.resume($0, message: $1)
    }

    private struct Pending { let session: ClaudeSession; var attempts: Int; var nextAttempt: Date }

    private var pending: [String: Pending] = [:]   // keyed by session id
    private var message = "Continue where you left off."
    private var pollSeconds: TimeInterval = 60
    private var inFlight = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.doppio.autoresume")

    private static let maxFailures = 5
    private static let backoffCap: TimeInterval = 300

    var waitingCount: Int { pending.count }

    // MARK: - Configuration

    /// Reconcile the watched set with the current settings. New sessions are
    /// queued for an immediate first attempt; unwatched ones are dropped.
    func configure(enabled: Bool, sessions: [ClaudeSession],
                   message: String, pollSeconds: TimeInterval) {
        self.message = message
        self.pollSeconds = max(30, min(600, pollSeconds))
        guard enabled else { stop(); pending.removeAll(); notifyWaiting(); return }

        let wanted = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in pending.keys where wanted[id] == nil { pending[id] = nil }
        let now = Date()
        for (id, s) in wanted where pending[id] == nil {
            pending[id] = Pending(session: s, attempts: 0, nextAttempt: now)
        }
        notifyWaiting()
        if pending.isEmpty { stop() } else { start() }
    }

    /// Reconfigure from the persisted settings (resolving watched tokens to
    /// sessions). Called at launch and whenever the user changes the settings.
    func applyPreferences() {
        let prefs = Preferences.shared
        let sessions = prefs.autoResumeSessions.compactMap(ClaudeSession.from(token:))
        configure(enabled: prefs.autoResumeEnabled, sessions: sessions,
                  message: prefs.autoResumeMessage, pollSeconds: prefs.autoResumePollSeconds)
    }

    func shutdown() { stop(); pending.removeAll() }

    // MARK: - Scheduling

    private func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: pollSeconds)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stop() { timer?.cancel(); timer = nil }

    private func earliestDue(at now: Date) -> Pending? {
        pending.values.filter { $0.nextAttempt <= now }
            .min { $0.nextAttempt < $1.nextAttempt }
    }

    private func tick() {
        guard !inFlight, let due = earliestDue(at: Date()) else { return }
        attempt(due)
    }

    private func attempt(_ p: Pending) {
        inFlight = true
        let session = p.session, msg = message, provider = resumeProvider
        queue.async { [weak self] in
            let outcome = provider(session, msg)
            DispatchQueue.main.async { self?.handle(outcome, for: session) }
        }
    }

    /// Test hook: synchronously attempt the earliest-due session (via
    /// `resumeProvider`) and apply its outcome, bypassing the timer and
    /// background queue. Returns the attempted session id, or nil if none is
    /// due at `now`. Uses the same selection logic as `tick()`.
    func stepForTesting(now: Date) -> String? {
        guard let due = earliestDue(at: now) else { return nil }
        handle(resumeProvider(due.session, message), for: due.session)
        return due.session.id
    }

    private func handle(_ outcome: ResumeOutcome, for session: ClaudeSession) {
        inFlight = false
        guard var p = pending[session.id] else { notifyWaiting(); return }
        p.attempts += 1

        switch outcome {
        case .resumed:
            pending[session.id] = nil
            onEvent?(.resumed(session.project))
        case .rateLimited(let reset):
            p.nextAttempt = reset ?? Date().addingTimeInterval(
                Self.backoffDelay(attempt: p.attempts, base: pollSeconds, cap: Self.backoffCap))
            pending[session.id] = p
        case .needsPermission:
            pending[session.id] = nil
            onEvent?(.needsInteraction(session.project))
        case .authRequired:
            pending[session.id] = nil
            onEvent?(.authRequired)
        case .cliMissing:
            pending.removeAll()
            onEvent?(.cliMissing)
        case .sessionNotFound:
            pending[session.id] = nil
            onEvent?(.failed(session.project))
        case .failed:
            if p.attempts >= Self.maxFailures {
                pending[session.id] = nil
                onEvent?(.failed(session.project))
            } else {
                p.nextAttempt = Date().addingTimeInterval(
                    Self.backoffDelay(attempt: p.attempts, base: pollSeconds, cap: Self.backoffCap))
                pending[session.id] = p
            }
        }

        if pending.isEmpty { stop() }
        notifyWaiting()
    }

    private func notifyWaiting() { onWaitingChange?(pending.count) }

    // MARK: - Pure helper (tested)

    /// Exponential backoff: attempt 1 → base, then doubling, capped.
    static func backoffDelay(attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard attempt > 1 else { return min(cap, base) }
        return min(cap, base * pow(2.0, Double(min(attempt - 1, 8))))
    }
}
