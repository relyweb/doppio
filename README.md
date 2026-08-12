# Doppio

A tiny macOS menu-bar app that keeps your Mac awake for long-running **agentic
tasks** — Claude Code, [omp](https://github.com/), opencode, or anything else —
including **while the screen is locked** and **with the lid closed**.

It is a more reliable, task-aware replacement for `caffeinate`.

## Why not just `caffeinate`?

`caffeinate` has two gaps that break agent workflows:

1. **Lock the screen and the task often stops / the Mac still sleeps.** A basic
   idle assertion isn't always enough.
2. **Closing the lid always sleeps the Mac.** Power assertions *cannot* prevent
   clamshell (lid-closed) sleep — only disabling sleep at the `pmset` level can,
   and that needs root.

Doppio handles both, and it can decide *on its own* when to stay awake by
watching for your agent processes.

## What it does

- **Task-aware.** While Claude Code, omp, or opencode is running an actual
  interactive session, the Mac stays awake — then it's allowed to sleep again
  (after a short grace period). Detection is **presence-based, not CPU-based**,
  so a long model call that uses ~0% CPU never lets the Mac doze off mid-task.
  Persistent Claude Code background daemons (`claude daemon`, `bg-pty-host`,
  `bg-spare`) are ignored so an idle machine isn't pinned awake forever.
- **Timer mode (no integration needed).** Keep awake for 15 min … 8 hours, or
  **until a specific wall-clock time** — works even when locked.
- **Manual mode.** "Keep Awake Indefinitely" toggle.
- **Stays awake when locked.** Uses an IOKit `PreventUserIdleSystemSleep`
  assertion (the reliable primitive `caffeinate` wraps).
- **Works with the lid closed.** Optional "Allow When Lid Closed" flips
  `pmset disablesleep` (one admin prompt) and reverts it the moment the Mac is
  allowed to sleep again or the app quits.
- **Keep Display On** (optional) — otherwise only the system stays awake and the
  screen may turn off, which is usually what you want for a locked machine.
- **Runs in the background** as a menu-bar agent (no Dock icon), with optional
  **Start at Login**.
- **Custom processes** — add any other process name (e.g. `aider`,
  `cursor-agent`) to the watch list.

## Install via Homebrew

Doppio is distributed as a Homebrew **cask** from its own tap:

```bash
brew tap relyweb/doppio https://github.com/relyweb/doppio
brew trust relyweb/doppio        # third-party taps must be trusted once
brew install --cask doppio
open -a Doppio                    # launches the menu-bar app
```

Upgrade / remove:

```bash
brew upgrade --cask doppio
brew uninstall --cask doppio     # add --zap to also delete preferences
```

> The app is ad-hoc signed, not notarized (no Apple Developer ID). The cask's
> `postflight` strips the Gatekeeper quarantine flag on install, so it launches
> without the "unidentified developer" prompt. If macOS still blocks it, run
> `xattr -dr com.apple.quarantine /Applications/Doppio.app` or approve it under
> System Settings > Privacy & Security.

## Requirements

- macOS 13 or later (built and tested on macOS 26 / Apple Silicon).
- Swift toolchain (Xcode or Command Line Tools).

## Build

```bash
./build.sh
```

This compiles a release binary and assembles `Doppio.app` (ad-hoc signed).

```bash
open ./Doppio.app                      # run it
cp -R ./Doppio.app /Applications/       # install it
```

The espresso-cup icon appears in the menu bar. Filled = awake, outline = sleep
allowed.

## How it decides to stay awake

The Mac is kept awake if **any** of these is true:

```
manual toggle ON
  OR  timer active (not yet expired)
  OR  an enabled integration/custom process is running (+ grace period)
```

When none hold, the assertion is released and (if it was set) `disablesleep` is
restored to 0, so normal sleep resumes.

## The lid-closed prompt

Enabling **Allow When Lid Closed** runs:

```
sudo pmset -a disablesleep 1
```

via a macOS admin-authorization dialog (no password stored). It is reverted to
`0` when Doppio goes idle or quits. If Doppio is force-killed while it was set,
run `sudo pmset -a disablesleep 0` once to restore normal behavior.

## Verify it works

Headless check that the OS actually registered the assertion:

```bash
"Doppio.app/Contents/MacOS/Doppio" --selftest
# [selftest] assertion visible to pmset: true
# [selftest] assertion released: true
# [selftest] PASS
```

While the app runs you can also see its assertion live:

```bash
pmset -g assertions | grep Doppio
# pid NNNN(Doppio): ... PreventUserIdleSystemSleep named: "Doppio: running: ..."
```

## Project layout

```
Sources/Doppio/
  main.swift            App bootstrap (accessory app) + --selftest
  AwakeCoordinator.swift State machine: manual | timer | activity -> power state
  PowerManager.swift     IOKit assertions + pmset disablesleep (lid closed)
  ActivityMonitor.swift  Presence-based process detection (ps polling)
  MenuController.swift    Menu-bar UI
  Preferences.swift       UserDefaults-backed settings
  SelfTest.swift          Headless assertion verification
build.sh                 Compile + assemble Doppio.app
Info.plist               Bundle metadata (LSUIElement = menu-bar agent)
Resources/AppIcon.svg    Coffee-cup logo (design source)
Resources/AppIcon.icns   App icon compiled from the SVG (build.sh regenerates)
Casks/doppio.rb          Homebrew cask (this repo doubles as the tap)
release.sh               Build, zip, bump the cask, publish the GitHub release
```

## Releasing a new version

This repo is its own Homebrew tap: `Casks/doppio.rb` is the cask and GitHub
Releases host the built app. To cut a release (requires `gh` auth + push
access):

```bash
./release.sh 1.1.0        # builds, zips, updates the cask sha256, publishes v1.1.0
git commit -am "doppio 1.1.0" && git push
```

Users then get it with `brew upgrade --cask doppio`.
