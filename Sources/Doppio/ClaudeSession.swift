// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A discovered Claude Code CLI session that the user can choose to auto-resume.
///
/// Sessions live at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. We
/// read only the stable `cwd` field (from the first transcript record) plus the
/// filename (the session id) and the file's modification date — never chat
/// content — so discovery stays cheap and privacy-preserving.
struct ClaudeSession: Equatable, Identifiable {
    let id: String            // session UUID (transcript filename stem)
    let cwd: String           // absolute working directory to resume in
    let lastActivity: Date

    /// Display name: the project (last path component of `cwd`).
    var project: String {
        (cwd as NSString).lastPathComponent.isEmpty
            ? cwd : (cwd as NSString).lastPathComponent
    }

    /// Stable "<id>\t<cwd>" token used to persist a watched selection.
    var token: String { "\(id)\t\(cwd)" }

    static func from(token: String) -> ClaudeSession? {
        let parts = token.components(separatedBy: "\t")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return ClaudeSession(id: parts[0], cwd: parts[1], lastActivity: .distantPast)
    }
}

enum ClaudeSessionStore {
    /// `~/.claude/projects`
    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Most-recently-active sessions across all projects, newest first.
    static func recent(limit: Int = 40) -> [ClaudeSession] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var sessions: [ClaudeSession] = []
        for dir in projects {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let s = session(from: file) { sessions.append(s) }
            }
        }
        return Array(sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit))
    }

    /// Parse one transcript file into a `ClaudeSession`, reading only its first
    /// record's `cwd` and the file's modification time. Returns nil if the file
    /// has no usable `cwd`.
    static func session(from url: URL) -> ClaudeSession? {
        let id = url.deletingPathExtension().lastPathComponent
        guard !id.isEmpty else { return nil }
        guard let cwd = firstCwd(in: url) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return ClaudeSession(id: id, cwd: cwd, lastActivity: mtime)
    }

    /// Extract the `cwd` from the first JSONL record that carries one, without
    /// loading the whole (potentially large) transcript into memory.
    static func firstCwd(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        // Read up to ~64 KB looking for the first newline-delimited record.
        while buffer.count < 65_536 {
            guard let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty
            else { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let cwd = cwd(fromLine: line) { return cwd }
            }
        }
        return cwd(fromLine: buffer)
    }

    private static func cwd(fromLine line: Data) -> String? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cwd = obj["cwd"] as? String, !cwd.isEmpty else { return nil }
        return cwd
    }
}
