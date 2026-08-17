# Design — Auto-Resume for Claude Code (CLI-only MVP)

Status: Draft for review · Date: 2026-08-17 · Target: Doppio (Apache-2.0)

## 1. Goal

When a Claude Code CLI session stops because the account hit its usage limit,
Doppio automatically **continues the sessions the user selected** once the limit
resets — unattended, including with the lid closed. This extends Doppio's
existing promise ("keep the Mac awake for agentic tasks") from *passive* (don't
sleep) to *active* (pick the work back up), without the user babysitting the
reset clock.

Clean-room implementation: built from Claude Code's **documented CLI behavior**
and this spec. No code is taken from the GPL-3.0 `claude-resumer-mac` project
(that would force Doppio to GPL-3.0). Not affiliated with Anthropic.

## 2. Non-goals (explicitly out of MVP)

- Resuming the **Claude App** or **VS Code extension** (no API — needs fragile
  Accessibility/UI automation; deferred to a later phase).
- **Foreground/interactive** resume in a Terminal window (deferred; see §4).
- Bypassing Claude's permission or safety prompts (never; no
  `--dangerously-skip-permissions`).
- Editing/parsing chat content, or sending anything off-device.
- Multi-account or team features.

## 3. Background (from the spike)

- `claude` CLI (v2.1.x) supports `-r/--resume <session-id>`, `-c/--continue`,
  `-p/--print` (headless), and `--output-format json`.
- Sessions are stored at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`;
  each record carries `sessionId`, `cwd`, and `timestamp`. Mapping
  session → project dir → resume-in-cwd is trivial and uses only these stable
  fields.
- The **usage-limit reset time** is **not** in any dedicated cache. It only
  appears (if at all) inside the session transcript when a limit is hit — an
  **undocumented private format**. We therefore do not depend on it for
  correctness (see §4, Decision B).

## 4. Approaches considered & decisions

### Decision A — Resume mechanism: **headless `claude -p`** (chosen)

| Option | Pros | Cons |
|---|---|---|
| **A1. Headless `claude -p --resume <id> --output-format json "<msg>"`** (chosen) | Works **unattended / lid-closed** (Doppio's whole point); scriptable; parseable result; no UI-automation/TCC | Cannot answer interactive tool-permission prompts — fully "continues" only sessions whose tools are pre-authorized; permission-needed continuations surface an error instead of proceeding |
| A2. Foreground Terminal via `osascript`/`open` | Preserves interactive permission flow | Useless lid-closed/unattended (the core scenario); needs Automation TCC; steals focus; window management |

**Why A1:** the headline use case is "limit reset overnight, lid closed → work
continues," which is only possible headlessly. A1 is honest about its limit: for
coding sessions that need tool approvals, the resume returns a clear
"needs interaction" outcome that Doppio surfaces rather than silently stalling.
Foreground resume (A2) is a documented future enhancement for the attended case.

### Decision B — Timing: **retry-with-backoff**, reset-time as optional hint (chosen)

Attempting a resume **while still limited is cheap and non-destructive**: the
request is rejected (HTTP 429-equivalent) *before* a turn runs — no quota
consumed, no work done. The first attempt *after* reset is the real resume.
Therefore:

- Poll each watched session on a backoff schedule; classify the CLI result;
  on "limited" wait and retry, on "success" finish.
- **Optionally** read the reset time from the transcript's limit-error event to
  schedule the *first* attempt precisely and avoid pointless pre-reset 429s.
  Best-effort only; failure to parse just falls back to periodic backoff.

This avoids depending on the private reset format for correctness — more robust
than parsing it as the source of truth.

## 5. Architecture & components

New files (one responsibility each, matching Doppio's conventions):

- **`ClaudeSession.swift`** — `struct ClaudeSession { id, cwd, label, lastActivity }`
  plus a read-only discoverer that lists recent sessions from
  `~/.claude/projects/*/*.jsonl` (parsing only `sessionId`/`cwd`/`timestamp` and
  a short label from the first user message). Pure/testable file-parsing.
- **`ClaudeCLI.swift`** — thin wrapper that runs
  `claude -p --resume <id> --output-format json "<msg>"` in `cwd` and maps the
  process result to a pure `enum ResumeOutcome`:
  `.resumed`, `.rateLimited(reset: Date?)`, `.needsPermission`, `.authRequired`,
  `.sessionNotFound`, `.cliMissing`, `.failed(String)`. Classification logic is
  pure (input: exit code + stdout/stderr JSON) so it is unit-testable.
- **`AutoResumer.swift`** — `final class` state machine: owns the set of watched
  sessions and, for each, a per-session state (`idle` → `waiting(nextAttempt)` →
  `resuming` → `done`/`failed`). Computes backoff, invokes `ClaudeCLI`, emits
  events, and contributes a **keep-awake reason** to `AwakeCoordinator` while any
  session is pending. Attempts are **serialized** (one at a time) to avoid
  interleaved sessions.
- **Preferences** additions (in `Preferences.swift`): `autoResumeEnabled: Bool`
  (default false), `autoResumeSessions: [String]` (watched `id|cwd` pairs),
  `autoResumeMessage: String` (default `"Continue where you left off."`),
  `autoResumePollSeconds: TimeInterval` (default 60, clamped 30–600).
- **UI**: a new **"Auto-Resume"** Preferences tab (`PreferencesView.swift` +
  `SettingsModel.swift`) with an enable toggle, editable resume message, and a
  session picker (recent sessions listed by project + last-activity + label,
  checkboxes to watch). A menu-bar status line shows pending/next-attempt.
- **`SelfTest.swift`**: pure tests for outcome classification, backoff schedule,
  and session-metadata parsing (added under a new `--selftest-resume` flag).

Reused: `AwakeCoordinator` (keep-awake reason + tick), `Notifier` (toasts),
`Runtime` (paths), the battery policy (`effectiveActive`).

## 6. Data model & persistence

- Watched sessions persist in `UserDefaults` as `"<session-id>\t<cwd>"` strings
  (cwd captured at selection so a resume always runs in the right directory even
  if the transcript is pruned).
- Per-session runtime state (attempt count, next-attempt time, last outcome) is
  **in-memory only** (never persisted) — consistent with Doppio's rule that
  runtime state can't survive a crash/reboot.
- No new files under `~/.doppio`. Reading `~/.claude` is read-only.

## 7. Data flow / state machine

```
discover sessions (ClaudeSession) ──▶ user selects (Preferences)
        │
        ▼
AutoResumer (enabled):
  for each watched session, serialized:
    state=waiting(next)                 ← keep-awake reason ON while any waiting
      │ at next attempt (or parsed reset time):
      ▼
    ClaudeCLI.resume(id, cwd, msg) ──▶ ResumeOutcome
      ├─ .rateLimited(reset) → next = reset ?? now+backoff; stay waiting
      ├─ .resumed           → notify "continued"; state=done; drop keep-awake
      ├─ .needsPermission   → notify "needs interaction"; state=failed (stop)
      ├─ .authRequired      → notify "sign in to Claude"; state=failed
      ├─ .cliMissing        → notify once; disable feature
      └─ .failed/.notFound  → retry a few times, then failed + notify
```

- **Keep-awake integration:** while any watched session is `waiting`/`resuming`,
  `AutoResumer` reports an **automatic** keep-awake reason to the coordinator, so
  the Mac stays awake until reset — but, being *automatic*, it **yields to the
  battery floor** (won't drain below the soft/hard floor; honors pause-on-battery
  and lid-closed AC-only rules). This reuses `effectiveActive`.
- Backoff: exponential from `autoResumePollSeconds`, capped (e.g., 60s → 5m cap);
  reset-time hint overrides the first delay when available.

## 8. UX

- **Preferences → Auto-Resume tab:** enable toggle; multiline resume message
  (editable, default provided); scrollable list of recent Claude Code sessions
  (project folder name · relative last-activity · first-message snippet) with
  checkboxes; a note: *"Continues headlessly with your existing Claude
  permissions; sessions needing tool approval will report that instead of
  running."* + the "not affiliated with Anthropic" line.
- **Menu bar:** when armed, a status row — e.g., *"Auto-resume: 2 waiting · next
  10:42"* — and the reason appears in the existing tooltip/summary.
- **Notifications** (respect existing toggle): "Resumed <label>", "<label> needs
  interaction", "Sign in to Claude to auto-resume".

## 9. Safety, security, privacy

- **Opt-in** globally and per session; default off.
- Never bypasses Claude permissions/safety (no dangerous flags).
- **Local only**: reads `~/.claude` read-only, runs a local binary; nothing
  leaves the device.
- Runs the exact user-configured message; shows it before enabling.
- Respects battery policy (automatic reason → yields to floors) so auto-resume
  can never deep-discharge the Mac. Lid-closed inherits the existing AC-only
  daemon guarantees.
- `claude` is invoked by absolute path resolved once (via `which`/known install
  locations: `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin`),
  never from a mutable `PATH`; the message is passed as a process argument (no
  shell), so there is no command-injection surface.
- Trademark: "Claude Code" used nominatively (compatibility), with the
  non-affiliation disclaimer.

## 10. Error handling & edge cases

- `claude` not installed / not found → disable feature, notify once.
- Session file deleted/pruned → mark that session failed, notify, keep others.
- Not signed in / auth error → surface "sign in", stop retrying that session.
- Offline / transient error → bounded retries with backoff, then failed.
- Ambiguous CLI output (classifier can't tell) → treat as transient, retry a
  small number of times, then surface to the user (never loop forever).
- User quits / disables → cancel timers, drop keep-awake reason.
- Rapid re-enable while attempts in flight → serialize; no overlapping resumes.

## 11. Testing

- **Pure unit tests** (`--selftest-resume`, exit non-zero on failure, CI-safe):
  1. `ClaudeCLI` outcome classifier over captured fixture outputs (success JSON,
     rate-limit error, auth error, missing-session, malformed) → correct
     `ResumeOutcome`.
  2. Backoff schedule (monotonic, capped; reset-time hint honored).
  3. `ClaudeSession` metadata parsing from a synthetic `.jsonl` fixture.
- **Smoke** (manual): run `claude -p --resume <id> "<msg>"` against a real
  session and confirm a `.resumed` classification; confirm keep-awake reason
  appears in `--diag` while a session is `waiting`.
- The real rate-limit path can't be unit-triggered; the classifier is validated
  against **captured** 429 output (to be recorded during implementation from a
  real limit event) and defended by the "ambiguous → bounded retry" fallback.

## 12. Decisions to confirm (review gate)

1. **Mechanism = headless `-p` for MVP** (Decision A). Accept that coding
   sessions needing tool approval will report "needs interaction" rather than
   run? (Alternative: also ship foreground Terminal resume now — larger scope.)
2. **Session selection UX** = explicit picker of recent sessions (vs. "watch the
   newest session per project automatically").
3. **Default resume message** = `"Continue where you left off."` — good?
4. **Battery interaction** = treat "waiting to resume" as an *automatic*
   keep-awake reason (yields to the battery floor). Confirm you don't want it to
   hold awake below the floor.
5. **Spec location** = top-level `specs/` (kept out of the `docs/` Pages site).
   OK?
6. **Scope of "waiting" detection** — MVP relies on retry+backoff (safe 429s)
   rather than proactively parsing which sessions are limited. Acceptable?

## 13. Rollout / future work

- Phase 1 (this MVP): CLI-only, headless, retry/backoff, picker, keep-awake tie-in.
- Phase 2: precise reset-time parsing as a first-attempt optimization.
- Phase 3 (separate design): Claude App / VS Code resume via Accessibility, and
  attended foreground Terminal resume.
- Verify exact `claude` rate-limit JSON shape during implementation and lock the
  classifier fixtures to it.
