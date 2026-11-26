import Foundation

/// Moves a session to another account when its own is near a usage limit: the session exits, and
/// the same conversation resumes in a new Ghostty tab under the other profile (same folder, model,
/// effort). This works because the profiles share `projects/`, where the transcripts live.
/// Only between profiles of the same `group`.
enum Move {
    /// From this much of the 5-hour or 7-day limit used, the panel offers to move.
    static let offerAtUsed = 85.0
    static let exitTimeoutSeconds: TimeInterval = 20

    enum Refusal: Error, CustomStringConvertible {
        case noTarget(String), background, busy, waiting(String), shell, subagents([String])
        case notFound, typingFailed(String), stillRunning, openFailed(String)

        var description: String {
            switch self {
            case .noTarget(let why): return why
            case .background: return "it is a background session with no terminal tab to exit"
            case .busy: return "it is mid-turn; wait for it to finish, then move it"
            case .waiting(let why): return "it is waiting on \(why); deal with that first"
            case .shell: return "a background shell is still running in it and would stop. Wait, or force it."
            case .subagents(let a): return "\(a.count) subagent(s) still running (\(a.joined(separator: ", "))); they would be lost. Wait, or force it."
            case .notFound: return "could not find its Ghostty tab"
            case .typingFailed(let e): return "could not type into its tab: \(e)"
            case .stillRunning: return "it did not exit within \(Int(exitTimeoutSeconds)) s after /exit; nothing was moved"
            case .openFailed(let e): return "it exited, but the new tab did not open: \(e). Resume it yourself with the command above."
            }
        }
    }

    /// How much of the tighter limit is used, if that window has not reset yet. No data counts as 0.
    static func used(_ p: Profile, _ usage: [AccountUsage], now: Date = Date()) -> Double {
        guard let u = usage.first(where: { $0.profile == p }) else { return 0 }
        return [u.fiveHour, u.sevenDay].compactMap { $0 }.filter { $0.resetsAt > now }.map(\.usedPercent).max() ?? 0
    }

    /// Whether this account's limits have been seen. An account that is already out never reports
    /// them (Claude Code only sends them with a successful reply), so unseen can mean full.
    static func seen(_ p: Profile, _ usage: [AccountUsage]) -> Bool {
        usage.contains { $0.profile == p }
    }

    /// Profiles that can take this session, most headroom first.
    static func targets(for s: Session, usage: [AccountUsage]) -> [Profile] {
        Config.profiles
            .filter { $0 != s.profile && $0.group == s.profile.group }
            // Seen accounts with room first: an unseen one may be out.
            .sorted { (seen($0, usage) ? 0 : 1, used($0, usage)) < (seen($1, usage) ? 0 : 1, used($1, usage)) }
    }

    /// The profile the panel offers, when the session's own account is near a limit and another has room.
    static func offer(for s: Session, usage: [AccountUsage]) -> Profile? {
        guard !s.isBackground, used(s.profile, usage) >= offerAtUsed,
              let t = targets(for: s, usage: usage).first, used(t, usage) < offerAtUsed else { return nil }
        return t
    }

    static func command(for s: Session, to target: Profile, statusline: [String: [String: Any]]) -> String {
        let l = Handoff.launch(for: s, statusline: statusline)
        var cmd = target.launch + " --resume \(s.id)"
        if let m = l.model { cmd += " --model \(m)" }
        if let e = l.effort { cmd += " --effort \(e)" }
        return cmd
    }

    /// Runs the move, blocking. `to` nil picks the target with the most headroom.
    static func run(_ s: Session, to: Profile?, statusline: [String: [String: Any]], usage: [AccountUsage],
                    force: Bool, progress: (String) -> Void) -> Result<Profile, Refusal> {
        let candidates = targets(for: s, usage: usage)
        guard let target = to ?? candidates.first else {
            return .failure(.noTarget("no other profile shares the group \"\(s.profile.group)\" with \(s.profile.name); set \"group\" in the config"))
        }
        guard candidates.contains(target) else {
            return .failure(.noTarget("\(target.name) is not in the same group as \(s.profile.name)"))
        }
        if s.isBackground { return .failure(.background) }
        switch s.status {
        case .busy: return .failure(.busy)
        case .waiting: return .failure(.waiting(WaitReasons.reason(for: s, statusline: statusline).summary))
        case .shell where !force: return .failure(.shell)
        default: break
        }
        let agents = Subagents.running(for: s, statusline: statusline)
        if !agents.isEmpty && !force { return .failure(.subagents(agents.map(\.description))) }

        let cmd = command(for: s, to: target, statusline: statusline)
        progress("resume command: \(cmd)")
        switch GhosttyInput.type("/exit", into: s) {
        case .typed: progress("asked \(s.name) to exit")
        case .notFound: return .failure(.notFound)
        case .failed(let e): return .failure(.typingFailed(e))
        }
        // Wait for the process to go, so two sessions never write one transcript.
        let deadline = Date().addingTimeInterval(exitTimeoutSeconds)
        while kill(s.pid, 0) == 0 {
            if Date() > deadline { return .failure(.stillRunning) }
            usleep(300_000)
        }
        progress("\(s.name) exited")
        if let err = Handoff.openTab(cwd: s.cwd, command: cmd) { return .failure(.openFailed(err)) }
        progress("resumed on \(target.title) in a new Ghostty tab")
        return .success(target)
    }
}
