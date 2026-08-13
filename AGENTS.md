# Repository Guidelines

## Project Overview

`doppio` (**Doppio**) is a tiny macOS menu-bar app that keeps a Mac awake for
long-running **agentic tasks** (Claude Code, omp, opencode, Codex, Gemini, or
any custom process) — including while the screen is locked and the lid is
closed. It is a task-aware replacement for `caffeinate`: it can keep awake by
manual toggle, a timer/wall-clock deadline, a recurring weekly schedule, until a
chosen process exits, or automatically while a watched agent process is running.

Distributed as a Homebrew **cask** via the `relyweb/doppio` tap; the cask itself
lives in a separate repo (`relyweb/homebrew-doppio`). See `README.md` for the
full user-facing feature list, battery/thermal safety policy, and the
`~/.doppio/active` task-token integration.

## Architecture & Data Flow

Single Swift Package Manager **executable** target (`Doppio`), no external
dependencies. AppKit for the menu bar / HUD, SwiftUI for the Preferences window,
Carbon for the global hotkey, IOKit for power state.

Entry point → decision → power state:

1. `main.swift` — parses headless flags (`--selftest*`, `--diag`, `--render-*`)
   and exits early for them; otherwise boots an `NSApplication` accessory app
   (`LSUIElement`, no Dock icon) with `AppDelegate`, which wires the
   `MenuController`, the global hotkey, and the coordinator.
2. `AwakeCoordinator` — the state machine. On every tick it OR-combines three
   independent reasons to stay awake — **manual** toggle, **timer/deadline**,
   and **activity** (a watched integration/custom process is running, or a live
   `~/.doppio/active` token exists) — applies the battery policy, and reconciles
   them into one desired power state.
3. `PowerManager` — applies that state via IOKit assertions
   (`PreventUserIdleSystemSleep`, optional `PreventUserIdleDisplaySleep`) and,
   for lid-closed, `pmset disablesleep` through one admin `osascript` prompt. It
   writes a sentinel (`~/.doppio/lid-sleep-disabled`) so a crash can be recovered
   on next launch. `apply(...)` is idempotent — only real transitions do work.

Inputs feeding the coordinator: `ActivityMonitor` (process presence +
`~/.doppio/active` tokens), `PowerSource` (AC/battery + charge % via IOKit),
`Schedule` (pure weekly-window logic), and `Preferences` (UserDefaults). Outputs:
`PowerManager` (system state) and `Notifier` (UserNotifications toasts).

## Key Directories

```
.
├── Sources/Doppio/         Swift source (one executable target)
├── Resources/              AppIcon.svg (design source) + AppIcon.icns
├── docs/                   GitHub Pages landing site + screenshots
├── build.sh                Compile + assemble Doppio.app (ad-hoc signed)
├── release.sh              Build, zip, publish GitHub release, bump tap cask
├── Package.swift           SwiftPM manifest (swift-tools 5.9, macOS 13+)
└── Info.plist              Bundle metadata (LSUIElement menu-bar agent)
```

`.build/`, `Doppio.app/`, `dist/`, and `Resources/AppIcon.iconset/` are
generated and gitignored.

## Development Commands

```bash
swift build -c release                 # compile the binary
./build.sh                             # compile + assemble ad-hoc-signed Doppio.app
open ./Doppio.app                      # run it (menu-bar icon; no Dock icon)
cp -R ./Doppio.app /Applications/      # install it
./release.sh <version>                 # e.g. ./release.sh 0.2.1 — build, zip, publish, bump cask
```

There is **no XCTest suite**. Verification is via headless flags on the built
binary (also usable straight from SwiftPM's bin path):

```bash
Doppio.app/Contents/MacOS/Doppio --selftest        # assertion registers + releases (exits nonzero on fail)
Doppio.app/Contents/MacOS/Doppio --selftest-modes  # manual/timer exclusivity, battery policy, signals, schedule
Doppio.app/Contents/MacOS/Doppio --selftest-power  # battery % fetch, cross-checked with pmset
Doppio.app/Contents/MacOS/Doppio --diag            # power source, live signal tokens, current policy

# Offscreen UI renders (verify layout without a display):
Doppio.app/Contents/MacOS/Doppio --render-prefs <tab> <out.png>   # tab: general|integrations|schedule|advanced
Doppio.app/Contents/MacOS/Doppio --render-hud <out.png>           # the keep-awake HUD panel
```

Watch the live assertion while the app runs: `pmset -g assertions | grep Doppio`.

## Code Conventions & Common Patterns

- Swift 5.9, macOS 13+ minimum (built/tested on macOS 26, Apple Silicon).
- UI/state types that touch AppKit run on the main actor (`@MainActor` where
  annotated, e.g. `HUD`, `PreferencesRenderer`); the coordinator and its inputs
  are driven from the main thread.
- Types are `final class` unless there's a reason otherwise; stateless logic and
  namespaces are `enum` with `static` members (`Runtime`, `Schedule`, `SelfTest`,
  `PreferencesRenderer`).
- Each file carries a doc comment stating its single responsibility; keep that
  one-file-one-role split when adding code.
- Reconcilers are **idempotent** — recompute-and-apply is called on every tick,
  so new state must be safe to re-apply without side effects.
- Settings persist in `UserDefaults` via `Preferences`; runtime IPC uses simple,
  scriptable `~/.doppio` paths defined once in `Runtime` — never hardcode those
  paths elsewhere.
- Privileged actions (`pmset disablesleep`) go through `PowerManager`'s single
  `osascript` admin prompt and must always be reverted on idle/quit, with a
  sentinel for crash recovery.

## Important Files

- `Sources/Doppio/main.swift` — bootstrap, headless flag dispatch, `AppDelegate`.
- `Sources/Doppio/AwakeCoordinator.swift` — the keep-awake state machine.
- `Sources/Doppio/PowerManager.swift` — IOKit assertions + `pmset` + crash recovery.
- `Sources/Doppio/ActivityMonitor.swift` — process detection + `~/.doppio/active` tokens.
- `Sources/Doppio/Runtime.swift` — well-known `~/.doppio` paths.
- `Sources/Doppio/SelfTest.swift` — headless self-tests behind the CLI flags.
- `Package.swift`, `Info.plist`, `build.sh`, `release.sh` — build/release config.

## Runtime/Tooling Preferences

- Runtime: native macOS (Apple Silicon or Intel), macOS 13+.
- Build: Swift toolchain (Xcode or Command Line Tools) + SwiftPM. No package
  manager beyond SwiftPM; **no third-party dependencies** — keep it that way
  unless there's a strong reason.
- No committed lockfile (no external deps to pin).
- `Resources/AppIcon.icns` is regenerated from `Resources/AppIcon.svg` by
  `build.sh` when `rsvg-convert` is available; the compiled `.icns` is committed
  as a fallback.

## Testing & QA

No unit-test framework is configured. Treat the `--selftest`, `--selftest-modes`,
and `--selftest-power` flags as the regression suite: they exit nonzero on
failure and are safe to run in CI (they acquire and release real assertions).
For UI changes, use `--render-prefs` / `--render-hud` to produce a PNG and verify
layout/geometry without a display. When adding behavior, prefer extending an
existing `SelfTest.run*` path over introducing a parallel testing convention.
