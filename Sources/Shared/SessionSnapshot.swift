import Foundation

/// The open Claude sessions, saved continually so they can be reopened after a restart or crash.
///
/// `current.json` is rewritten while sessions are open. When the panel starts after a reboot it
/// moves the old file to `before-restart.json` (the boot time inside it no longer matches), which
/// is what a restore reads; a restore renames it to `restored-<time>.json`.
struct SavedSession: Codable {
    let sessionId: String
    let name: String
    let cwd: String
    let profile: String
    let branch: String?
    let claim: String?
    let lastPrompt: String?
    /// Optional so saves written before these fields existed still load.
    let background: Bool?
    let runningSubagents: [RunningSubagent]?

    var resumeCommand: String { "\(Config.profile(named: profile)?.launch ?? "claude") --resume \(Shell.quote(sessionId))" }
}

struct SessionSnapshot: Codable {
    let savedAt: Date
    let bootTime: Date
    let sessions: [SavedSession]
}

enum SessionSnapshots {
    static let dir = Config.stateDir.appendingPathComponent("snapshots")
    static let current = dir.appendingPathComponent("current.json")
    static let beforeRestart = dir.appendingPathComponent("before-restart.json")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(_ url: URL) -> SessionSnapshot? {
        (try? Data(contentsOf: url)).flatMap { try? decoder.decode(SessionSnapshot.self, from: $0) }
    }

    /// Saves every open session, background ones included (nothing restarts the background daemon at
    /// login), with the subagents each has running. An empty list never overwrites a saved one, so a
    /// fresh boot cannot wipe the last state.
    static func save(_ sessions: [Session], statusline: [String: [String: Any]], bootTime: Date,
                     branch: (String) -> String? = { _ in nil }) {
        rotateIfRebooted(bootTime: bootTime)
        let keep = sessions
        guard !keep.isEmpty else { return }
        let saved = keep.map { s in
            SavedSession(
                sessionId: s.id, name: s.name, cwd: s.cwd, profile: s.profile.rawValue,
                branch: branch(s.cwd), claim: Claims.read(for: s.id)?.note,
                lastPrompt: TranscriptReader.context(for: s, statusline: statusline,
                                                     prompts: 1, replies: 0, actions: 0).lastPrompt
                    .map { oneLine($0, max: 200) },
                background: s.isBackground,
                runningSubagents: Subagents.running(for: s, statusline: statusline)
            )
        }
        let snap = SessionSnapshot(savedAt: Date(), bootTime: bootTime, sessions: saved)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? encoder.encode(snap).write(to: current, options: .atomic)
    }

    /// After a reboot the saved boot time is stale: that file is the state before the restart.
    static func rotateIfRebooted(bootTime: Date) {
        guard let old = load(current), abs(old.bootTime.timeIntervalSince(bootTime)) > 60 else { return }
        try? FileManager.default.removeItem(at: beforeRestart)
        try? FileManager.default.moveItem(at: current, to: beforeRestart)
    }

    /// Sessions from before the last restart that are not already open again.
    static func pendingRestore(live: [Session]) -> SessionSnapshot? {
        guard let snap = load(beforeRestart) else { return nil }
        let open = Set(live.map(\.id))
        let missing = snap.sessions.filter { !open.contains($0.sessionId) }
        return missing.isEmpty ? nil : SessionSnapshot(savedAt: snap.savedAt, bootTime: snap.bootTime, sessions: missing)
    }

    static func markRestored() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let to = dir.appendingPathComponent("restored-\(f.string(from: Date())).json")
        try? FileManager.default.moveItem(at: beforeRestart, to: to)
    }

    /// Opens one Ghostty tab per session, in a new window, resuming each conversation in its folder.
    /// Returns an error message, or nil on success.
    static func reopen(_ sessions: [SavedSession]) -> String? {
        let tabs = sessions.map { s -> String in
            let cmd = s.resumeCommand
            return """
              set cfg to new surface configuration
              set initial working directory of cfg to "\(appleScriptString(s.cwd))"
              set initial input of cfg to "\(appleScriptString(cmd))" & return
              if w is missing value then
                set w to new window with configuration cfg
              else
                new tab in w with configuration cfg
              end if
            """
        }.joined(separator: "\n")
        let script = """
        tell application "Ghostty"
          activate
          set w to missing value
        \(tabs)
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "\($0)" }
    }

}
