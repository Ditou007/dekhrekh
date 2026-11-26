import Foundation

/// One-click handoff for a session running low on context: the session writes a handoff file,
/// then a fresh session opens in a new Ghostty tab with the same folder, account, model and effort,
/// told to read it. The old session is left open.
enum Handoff {
    static var dir: URL { Config.stateDir.appendingPathComponent("handoffs") }
    /// Below this much context left, the panel offers the button.
    static let offerBelowRemaining = 30.0
    static let pollSeconds: UInt32 = 3
    static let timeoutSeconds: TimeInterval = 15 * 60

    enum Refusal: Error, CustomStringConvertible {
        case waiting(String), subagents([String]), notFound, typingFailed(String), timedOut(String), openFailed(String)

        var description: String {
            switch self {
            case .waiting(let why): return "it is waiting on \(why); typing would answer it. Deal with that first."
            case .subagents(let a): return "\(a.count) subagent(s) still running (\(a.joined(separator: ", "))); they would be lost. Wait, or force it."
            case .notFound: return "could not find its Ghostty tab"
            case .typingFailed(let e): return "could not type into its tab: \(e)"
            case .timedOut(let p): return "no handoff at \(p) after \(Int(timeoutSeconds / 60)) min; the old session may still be working on it"
            case .openFailed(let e): return "handoff written, but the new tab did not open: \(e)"
            }
        }
    }

    /// Sessions that already wrote a handoff (files are named <session-id prefix>-<time>.md).
    static func handedOff() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".md") }.compactMap { $0.split(separator: "-").first.map(String.init) })
    }

    struct Launch {
        let model: String?
        let effort: String?
    }

    /// The model and effort the session runs with, from its statusline feed.
    static func launch(for s: Session, statusline: [String: [String: Any]]) -> Launch {
        let payload = statusline[s.id]
        return Launch(model: (payload?["model"] as? [String: Any])?["id"] as? String,
                      effort: (payload?["effort"] as? [String: Any])?["level"] as? String)
    }

    static func request(path: String, newName: String, subagents: [String]) -> String {
        let base = "[via \(Config.cli) handoff] Your context is running low, so this work is moving to a fresh session. "
            + "Write a handoff to \(path) that a new session can continue from without this conversation: "
            + "the goal, what is done (with commits/PRs), what is in progress, decisions made and why, "
            + "open questions for the user, exact next steps, and the key files, commands and IDs. "
        guard !subagents.isEmpty else { return base + "Write only that file, then stop." }
        // Subagents report to the session that started them, so this one stays open as a relay
        // until they finish; the new session takes all new work.
        return base
            + "You have \(subagents.count) subagents still running (\(subagents.joined(separator: "; "))). "
            + "In the handoff, list each with what it will produce (branch, PR, files) and say its result will be forwarded. "
            + "After writing the file, stay open but start no new work: the new session, named \"\(newName)\", takes over everything new. "
            + "As each subagent finishes, send its report to that session with SendMessage (find its message name with `dekhrekh sessions`), "
            + "including PR links and anything that needs follow-up. Once all \(subagents.count) have reported and been forwarded, tell the user you are done."
    }

    /// Runs the whole handoff, blocking. `progress` gets a line per stage.
    static func run(_ s: Session, statusline: [String: [String: Any]], force: Bool,
                    progress: (String) -> Void) -> Result<String, Refusal> {
        if s.status == .waiting {
            return .failure(.waiting(WaitReasons.reason(for: s, statusline: statusline).summary))
        }
        let agents = Subagents.running(for: s, statusline: statusline)
        if !agents.isEmpty && !force { return .failure(.subagents(agents.map(\.description))) }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let file = dir.appendingPathComponent("\(s.id.prefix(8))-\(stamp).md")

        let newName = s.name + " (cont.)"
        switch GhosttyInput.type(request(path: file.path, newName: newName, subagents: agents.map(\.description)), into: s) {
        case .typed: progress("asked \(s.name) to write its handoff to \(file.path)")
        case .notFound: return .failure(.notFound)
        case .failed(let e): return .failure(.typingFailed(e))
        }

        // Done when the file exists with some substance and the session has finished its turn.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastSize = -1
        while Date() < deadline {
            sleep(pollSeconds)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            let current = SessionReader.readSessions(statusline: SessionReader.readStatusline(), includeStale: true)
                .first { $0.id == s.id }
            // `.shell` is a finished turn with a background shell still running; it never turns idle by itself.
            let finished = current.map { [.idle, .waiting, .shell].contains($0.status) } ?? true
            if size > 200 && size == lastSize && finished { break }
            lastSize = size
        }
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0 > 200 else {
            return .failure(.timedOut(file.path))
        }
        progress("handoff written (\(file.lastPathComponent))")

        let l = launch(for: s, statusline: statusline)
        var cmd = s.profile.launch
        if let m = l.model { cmd += " --model \(m)" }
        if let e = l.effort { cmd += " --effort \(e)" }
        cmd += " -n \(shellQuote(newName))"
        let relay = agents.isEmpty ? "" : " The previous session (\(s.name)) stays open only to forward results from its \(agents.count) running subagents; they arrive as messages from it. Take over all new work yourself."
        cmd += " " + shellQuote("Continue the work from the handoff in \(file.path). Read it first, then carry on with the next steps it lists." + relay)
        if let err = openTab(cwd: s.cwd, command: cmd) { return .failure(.openFailed(err)) }
        progress("opened a new session: \(cmd)")
        return .success(file.path)
    }

    static func openTab(cwd: String, command: String) -> String? {
        let script = """
        tell application "Ghostty"
          activate
          set cfg to new surface configuration
          set initial working directory of cfg to "\(appleEscape(cwd))"
          set initial input of cfg to "\(appleEscape(command))" & return
          new tab in front window with configuration cfg
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "\($0)" }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
