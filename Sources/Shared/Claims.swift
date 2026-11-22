import Foundation

/// What a session says it is working on, so another session can see it before touching the same
/// repo, branch or files. One file per session; a claim dies with its session.
struct Claim {
    let sessionId: String
    let note: String
    let cwd: String
    let branch: String?
    let at: Date
}

enum Claims {
    static let dir = Config.stateDir.appendingPathComponent("claims")

    static func read(for sessionId: String) -> Claim? {
        let url = dir.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let note = o["note"] as? String
        else { return nil }
        return Claim(sessionId: sessionId, note: note, cwd: o["cwd"] as? String ?? "",
                     branch: o["branch"] as? String,
                     at: Date(timeIntervalSince1970: (o["ts"] as? NSNumber)?.doubleValue ?? 0))
    }

    static func write(_ c: Claim) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o: [String: Any] = ["note": c.note, "cwd": c.cwd, "ts": c.at.timeIntervalSince1970]
        if let b = c.branch { o["branch"] = b }
        try JSONSerialization.data(withJSONObject: o).write(to: dir.appendingPathComponent("\(c.sessionId).json"),
                                                            options: .atomic)
    }

    static func clear(_ sessionId: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sessionId).json"))
    }

    /// The live session this process runs under: walk up parent pids until one is a session's pid.
    static func callingSession(among sessions: [Session]) -> Session? {
        let byPid = Dictionary(sessions.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var pid = getppid()
        for _ in 0..<32 where pid > 1 {
            if let s = byPid[pid] { return s }
            pid = parentPid(of: pid)
        }
        return nil
    }

    private static func parentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}
