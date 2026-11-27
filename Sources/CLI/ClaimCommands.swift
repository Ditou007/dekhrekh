import Foundation

/// `dekhrekh claim "<what I am working on>"`, `dekhrekh claim --clear`, `dekhrekh claims [--json]`.
func runClaim(args: [String]) -> Never {
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline, includeStale: true)
    guard let me = Claims.callingSession(among: sessions) else {
        FileHandle.standardError.write("dekhrekh claim: run this from inside a Claude session (its shell tool)\n".data(using: .utf8)!)
        exit(2)
    }
    if args.contains("--clear") {
        Claims.clear(me.id)
        print("cleared the claim for \(me.name)")
        exit(0)
    }
    let note = args.dropFirst().filter { !$0.hasPrefix("--") }.joined(separator: " ")
    guard !note.isEmpty else {
        FileHandle.standardError.write("usage: dekhrekh claim \"<repo, branch or files you are working on>\"\n".data(using: .utf8)!)
        exit(2)
    }
    let cwd = FileManager.default.currentDirectoryPath
    do {
        try Claims.write(Claim(sessionId: me.id, note: note, cwd: cwd, branch: Git.branch(at: cwd), at: Date()))
    } catch {
        FileHandle.standardError.write("dekhrekh claim: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    print("claimed for \(me.name): \(note)")
    let others = sessions.filter { $0.id != me.id }.compactMap { s in Claims.read(for: s.id).map { (s, $0) } }
    let clash = others.filter { _, c in c.cwd == cwd || (c.branch != nil && c.branch == Git.branch(at: cwd)) }
    if !clash.isEmpty {
        Frame.open()
        print("Heads up: other live sessions claim the same folder or branch:")
        clash.forEach { s, c in print("  \(s.name): \(c.note)  [\(c.branch ?? "-") in \(c.cwd)]") }
        Frame.close()
    }
    exit(0)
}

func runClaims(json: Bool) -> Never {
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline, includeStale: true)
    let rows = sessions.map { s in (s, Claims.read(for: s.id), Git.branch(at: s.cwd)) }
    if json {
        let out = rows.map { s, c, b -> [String: Any] in
            ["name": s.name, "session_id": s.id, "status": s.status.rawValue, "cwd": s.cwd,
             "branch": b ?? NSNull(), "claim": c?.note ?? NSNull(),
             "claimed_at": c.map { ISO8601DateFormatter().string(from: $0.at) as Any } ?? NSNull()]
        }
        let data = try! JSONSerialization.data(withJSONObject: Frame.wrap(out),
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }
    Frame.open()
    print("WHO IS WORKING ON WHAT (\(sessions.count) live sessions)")
    for (s, c, b) in rows {
        print("  \(s.name)  [\(s.status.rawValue)]")
        print("    folder \(s.cwd)\(b.map { "  branch \($0)" } ?? "")")
        print("    claim  \(c.map { "\($0.note)  (\(ago($0.at, now: Date())) ago)" } ?? "(none)")")
    }
    Frame.close()
    exit(0)
}
