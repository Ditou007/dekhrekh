import Foundation

/// `dekhrekh move <session> [--to=<profile>] [--force]`: the panel's "Continue on ..." button from a terminal.
func runMove(args: [String]) -> Never {
    let words = args.dropFirst().filter { !$0.hasPrefix("--") }
    let toName = args.first { $0.hasPrefix("--to=") }.map { String($0.dropFirst(5)) }
    guard let query = words.first else {
        FileHandle.standardError.write("usage: dekhrekh move <session> [--to=<profile>] [--force]\n".data(using: .utf8)!)
        exit(2)
    }
    var target: Profile?
    if let n = toName {
        guard let p = Config.profile(named: n) else {
            FileHandle.standardError.write("dekhrekh move: no profile named \"\(n)\" (have: \(Config.profiles.map(\.name).joined(separator: ", ")))\n".data(using: .utf8)!)
            exit(2)
        }
        target = p
    }
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline, includeStale: true)
    let hits = SessionReader.match(query, in: sessions)
    guard hits.count == 1, let s = hits.first else {
        FileHandle.standardError.write("dekhrekh move: \(hits.isEmpty ? "no" : "\(hits.count)") live sessions match \"\(query)\"\n".data(using: .utf8)!)
        exit(2)
    }
    if Claims.callingSession(among: sessions) != nil {
        print("dekhrekh move types /exit into a terminal as the user, so it does not run from inside a Claude session. Ask the user to click \"Continue on ...\" in the panel or run it themselves.")
        exit(3)
    }
    let usage = SessionReader.readUsage(statusline: statusline)
    let result = Move.run(s, to: target, statusline: statusline, usage: usage, force: args.contains("--force")) {
        print("... " + $0); fflush(stdout)
    }
    switch result {
    case .success(let p):
        print("done: \(s.name) continues on \(p.title)")
        exit(0)
    case .failure(let why):
        print("not done: \(why)")
        exit(1)
    }
}
