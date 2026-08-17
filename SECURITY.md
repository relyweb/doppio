# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for a
vulnerability.

Use GitHub's private advisory flow: the repository's **Security** tab →
**Report a vulnerability**. This is the preferred, private channel (now enabled
for this repo). If you can't use it, contact the maintainers privately rather
than filing a public issue.

Please include the affected version (see **About Doppio** in the menu, or
`Info.plist`), your macOS version, and steps to reproduce. We aim to acknowledge
reports within a few days.

## Scope and threat model

Doppio is a local, network-less macOS menu-bar app. The security-sensitive
surface is the optional **"Allow When Lid Closed"** feature, which installs a
small **root LaunchDaemon** (`com.doppio.keepawake.lidhelper`) via a single
admin-authorized prompt. The daemon:

- is installed only when you enable the feature, with root-owned files
  (`/Library/LaunchDaemons/…` and `/Library/Application Support/Doppio/…`);
- reads only a boolean flag (`~/.doppio/lid-desired`) and calls fixed
  absolute-path binaries — it never executes user-supplied data;
- enforces `pmset disablesleep` **only while on AC power** and forces normal
  sleep back on battery, so a lid-closed task cannot deep-discharge the battery.

Reports that demonstrate a way to obtain code execution as root, escape the
"AC-only" battery-safety guarantee, or exfiltrate data are especially welcome.

## Supported versions

Only the latest released version receives security fixes.
