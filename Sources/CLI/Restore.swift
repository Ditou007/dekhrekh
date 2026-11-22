import Foundation

func runSnapshot() -> Never {
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline)
    SessionSnapshots.save(sessions, statusline: statusline, bootTime: MacState.read().bootTime,
                          branch: TranscriptReader.gitBranch)
    let n = SessionSnapshots.load(SessionSnapshots.current)?.sessions.count ?? 0
    print("saved \(n) open session(s) to \(SessionSnapshots.current.path)")
    exit(0)
}

/// Reopens the sessions from before the last restart; with no restart since, offers the latest save.
func runRestore(dryRun: Bool) -> Never {
    let statusline = SessionReader.readStatusline()
    let live = SessionReader.readSessions(statusline: statusline)
    SessionSnapshots.rotateIfRebooted(bootTime: MacState.read().bootTime)
    let afterRestart = SessionSnapshots.pendingRestore(live: live)
    let fallback = SessionSnapshots.load(SessionSnapshots.current).map { snap in
        SessionSnapshot(savedAt: snap.savedAt, bootTime: snap.bootTime,
                        sessions: snap.sessions.filter { s in !live.contains { $0.id == s.sessionId } })
    }
    guard let snap = afterRestart ?? fallback, !snap.sessions.isEmpty else {
        print("nothing to restore: every saved session is already open")
        exit(0)
    }
    let when = ISO8601DateFormatter().string(from: snap.savedAt)
    print("\(afterRestart != nil ? "Before the restart" : "Saved, not open now") (saved \(when)): \(snap.sessions.count) session(s)")
    let foreground = snap.sessions.filter { $0.background != true }
    for s in snap.sessions {
        let tag = s.background == true ? "  [background: not reopened]" : ""
        print("  \(s.name)  [\(s.profile)]  \(s.cwd)\(s.branch.map { "  (\($0))" } ?? "")\(tag)")
        print("    \(s.resumeCommand)")
        for a in s.runningSubagents ?? [] {
            print("    interrupted subagent: \(a.description)  (ask the session to re-run it)")
        }
    }
    if dryRun { exit(0) }
    guard !foreground.isEmpty else {
        print("only background sessions saved; resume them with the commands above if you need them")
        exit(0)
    }
    if let err = SessionSnapshots.reopen(foreground) {
        print("could not open Ghostty tabs: \(err)")
        exit(1)
    }
    if afterRestart != nil { SessionSnapshots.markRestored() }
    print("opened \(foreground.count) tab(s) in a new Ghostty window")
    exit(0)
}

func runRestartCheck(json: Bool) -> Never {
    let statusline = SessionReader.readStatusline()
    let sessions = SessionReader.readSessions(statusline: statusline, includeStale: true)
    let check = RestartCheck.now(sessions: sessions, statusline: statusline)
    let mac = MacState.read()
    if json {
        let out: [String: Any] = ["safe": check.safe, "blockers": check.blockers,
                                  "restart_reasons": mac.restartReasons,
                                  "uptime_days": Int(mac.uptime / 86400)]
        let data = try! JSONSerialization.data(withJSONObject: Frame.wrap(out), options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(check.safe ? 0 : 1)
    }
    Frame.open()
    print("Mac up \(formatDuration(mac.uptime)), memory pressure \(mac.pressure.label)")
    print(mac.restartReasons.isEmpty ? "No strong reason to restart." : "A restart would help: " + mac.restartReasons.joined(separator: ", "))
    if check.safe {
        print("Safe to restart now: no session is busy and no subagent is running. Sessions are saved; reopen them with the panel or `dekhrekh restore`.")
    } else {
        print("Not yet. A restart now would interrupt:")
        check.blockers.forEach { print("  - \($0)") }
    }
    Frame.close()
    exit(check.safe ? 0 : 1)
}
