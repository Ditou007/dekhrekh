import Foundation

/// `dekhrekh tell <session> <message...>`
/// From your own terminal: types "[via dekhrekh tell] <message>" into that session's Ghostty tab.
/// From inside a Claude session: refuses, and names the peer to message with SendMessage instead,
/// so an agent's words never arrive looking like the user's.
func runTell(args: [String]) -> Never {
    let words = args.dropFirst().filter { !$0.hasPrefix("--") }
    guard words.count >= 2 else {
        FileHandle.standardError.write("usage: dekhrekh tell <session> \"<message>\"\n".data(using: .utf8)!)
        exit(2)
    }
    let query = words[words.startIndex]
    let message = words.dropFirst().joined(separator: " ")
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline, includeStale: true)
    let hits = SessionReader.match(query, in: sessions)
    guard hits.count == 1, let target = hits.first else {
        let msg = hits.isEmpty ? "no live session matches \"\(query)\"" : "\"\(query)\" matches \(hits.count) sessions"
        FileHandle.standardError.write("dekhrekh tell: \(msg). Live sessions:\n".data(using: .utf8)!)
        (hits.isEmpty ? sessions : hits).forEach {
            FileHandle.standardError.write("  \($0.name)  (message name: \($0.peerName ?? "-"))\n".data(using: .utf8)!)
        }
        exit(2)
    }

    if let me = Claims.callingSession(among: sessions) {
        guard me.id != target.id else {
            FileHandle.standardError.write("dekhrekh tell: that is this session\n".data(using: .utf8)!)
            exit(2)
        }
        print("""
        dekhrekh tell types into a terminal as the user, so it does not run from inside a Claude session.
        Send it with your SendMessage tool instead; it arrives labelled as a message from another session:
          SendMessage to: "\(target.peerName ?? target.name)"   (\(target.name), \(target.cwd))
        """)
        exit(3)
    }

    if target.status == .waiting {
        let why = WaitReasons.reason(for: target, statusline: statusline).summary
        print("not sent: \(target.name) is waiting on \(why). Pressing Enter there would answer it. Deal with that first, then retry.")
        exit(1)
    }

    switch GhosttyInput.type("[via dekhrekh tell] \(message)", into: target) {
    case .typed:
        let note = target.status == .busy ? " It is mid-task, so it reads the message when its current step finishes." : ""
        print("sent to \(target.name).\(note)")
        exit(0)
    case .notFound:
        print("not sent: could not find \(target.name)'s Ghostty tab (by title or folder).")
        exit(1)
    case .failed(let e):
        print("not sent: \(e)")
        exit(1)
    }
}
