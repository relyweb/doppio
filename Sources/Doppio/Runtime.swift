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

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }
}
