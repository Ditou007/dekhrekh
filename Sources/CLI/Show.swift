import Foundation

/// `dekhrekh show <session>`: enough context about another session to pick up from it
/// without the user copy-pasting.
func runShow(query: String, json: Bool) -> Never {
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline, includeStale: true)
    let q = query.lowercased()

    guard !q.isEmpty else {
        FileHandle.standardError.write("usage: dekhrekh show <session>\nlive sessions:\n".data(using: .utf8)!)
        sessions.forEach { FileHandle.standardError.write("  \($0.name)  (\($0.id.prefix(8)), pid \($0.pid))\n".data(using: .utf8)!) }
        exit(2)
    }

    let matches = SessionReader.match(query, in: sessions)
    guard matches.count == 1, let s = matches.first else {
        let msg = matches.isEmpty
            ? "no live session matches \"\(query)\". Live sessions:\n"
            : "\"\(query)\" matches \(matches.count) sessions, be more specific:\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
        (matches.isEmpty ? sessions : matches).forEach {
            FileHandle.standardError.write("  \($0.name)  (\($0.id.prefix(8)), pid \($0.pid), \($0.profile.tag))\n".data(using: .utf8)!)
        }
        exit(1)
    }

    let ctx = TranscriptReader.context(for: s, statusline: statusline)
    let branch = Git.branch(at: s.cwd)
    let now = Date()
    let iso = ISO8601DateFormatter()

    if json {
        let out: [String: Any] = [
            "name": s.name, "title": ctx.title ?? NSNull(), "session_id": s.id, "pid": s.pid,
            "profile": s.profile.rawValue, "status": s.status.rawValue,
            "status_since": iso.string(from: s.statusSince),
            "cwd": s.cwd, "branch": branch ?? NSNull(),
            "context_remaining_pct": s.ctxRemaining ?? NSNull(),
            "transcript": ctx.transcriptPath ?? NSNull(),
            "recent_prompts": ctx.prompts.map { p -> [String: Any] in
                ["at": p.at.map { iso.string(from: $0) as Any } ?? NSNull(), "text": p.text]
            },
            "latest_replies": ctx.replies,
            "recent_actions": ctx.actions.map { ["tool": $0.tool, "detail": $0.detail] },
        ]
        let data = try! JSONSerialization.data(withJSONObject: Frame.wrap(out), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }

    let rule = String(repeating: "─", count: 60)
    Frame.open()
    print("\(s.name)  [\(s.profile.tag), \(s.status.rawValue) for \(ago(s.statusSince, now: now))]")
    print("  folder   \(s.cwd)\(branch.map { "  (branch \($0))" } ?? "")")
    print("  session  \(s.id)  pid \(s.pid)  ctx left \(s.ctxRemaining.map { "\(Int($0))%" } ?? "-")")
    if let peer = s.peerName {
        if Config.messageable(s) {
            print("  message  SendMessage to \"\(peer)\" (from an agent) or `dekhrekh tell \(peer) \"...\"` (from your terminal)")
        } else {
            print("  message  not reachable with SendMessage: it runs on the \(s.profile.title) profile and this session on \(Config.callerProfile?.title ?? "another"). Ask the user to pass it on, or to run `dekhrekh tell \"\(peer)\" \"...\"` from their terminal.")
        }
    }
    if let t = ctx.transcriptPath { print("  log      \(t)") }

    print("\nRecent prompts from the user\n\(rule)")
    if ctx.prompts.isEmpty { print("  (none found)") }
    for p in ctx.prompts {
        let when = p.at.map { ago($0, now: now) + " ago" } ?? ""
        print("• \(when)\n  \(p.text.replacingOccurrences(of: "\n", with: "\n  "))")
    }

    print("\nLatest replies\n\(rule)")
    if ctx.replies.isEmpty { print("  (none found)") }
    for r in ctx.replies {
        print(truncate(r, max: 2500))
        print("")
    }

    print("Recent tool calls (oldest first)\n\(rule)")
    for a in ctx.actions { print("  \(a.tool.padding(toLength: 10, withPad: " ", startingAt: 0)) \(a.detail)") }
    Frame.close()
    exit(0)
}

private func truncate(_ s: String, max: Int) -> String {
    s.count > max ? String(s.prefix(max)) + "\n  … (truncated; full text in the log above)" : s
}
