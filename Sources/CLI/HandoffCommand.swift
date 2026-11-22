import Foundation

/// `dekhrekh handoff <session> [--force]`: the panel's "Hand off" button from a terminal.
func runHandoff(args: [String]) -> Never {
    let words = args.dropFirst().filter { !$0.hasPrefix("--") }
    guard let query = words.first else {
        FileHandle.standardError.write("usage: dekhrekh handoff <session> [--force]\n".data(using: .utf8)!)
        exit(2)
    }
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline, includeStale: true)
    let hits = SessionReader.match(query, in: sessions)
    guard hits.count == 1, let s = hits.first else {
        FileHandle.standardError.write("dekhrekh handoff: \(hits.isEmpty ? "no" : "\(hits.count)") live sessions match \"\(query)\"\n".data(using: .utf8)!)
        exit(2)
    }
    if Claims.callingSession(among: sessions) != nil {
        print("dekhrekh handoff types into a terminal as the user, so it does not run from inside a Claude session. Ask the user to click Hand off in the panel or run it themselves.")
        exit(3)
    }
    let result = Handoff.run(s, statusline: statusline, force: args.contains("--force")) { print("... " + $0); fflush(stdout) }
    switch result {
    case .success(let path):
        print("done: \(s.name) handed off; handoff at \(path)")
        exit(0)
    case .failure(let why):
        print("not done: \(why)")
        exit(1)
    }
}
