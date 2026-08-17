// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Well-known filesystem locations Doppio uses at runtime.
///
/// `~/.doppio` is intentionally a simple, scriptable path (not buried in
/// Application Support) so any tool can signal activity with one line of shell.
enum Runtime {
    /// `~/.doppio`
    static let directory: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".doppio", isDirectory: true)

    /// `~/.doppio/active` — presence of a live token here keeps the Mac awake.
    static let activeDirectory: URL =
        directory.appendingPathComponent("active", isDirectory: true)

    /// `~/.doppio/lid-sleep-disabled` — sentinel proving we set `pmset
    /// disablesleep 1`, so a crash can be recovered from on next launch.
    static let lidSentinel: URL =
        directory.appendingPathComponent("lid-sleep-disabled")

    /// `~/.doppio/lid-desired` — Doppio writes "1"/"0" here to tell the
    /// privileged lid helper whether it wants sleep disabled. The helper only
    /// honors a *fresh* "1" (Doppio rewrites it as a heartbeat) and only on AC.
    static let desiredFile: URL =
        directory.appendingPathComponent("lid-desired")

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }
}
