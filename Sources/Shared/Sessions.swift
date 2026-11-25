import Foundation

enum SessionStatus: String {
    case waiting, busy, idle, shell, unknown

    var rank: Int {
        switch self {
        case .waiting: return 0
        case .busy: return 1
        case .shell: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }
}

/// "3 live" or "3 live · 1 background": background sessions (no terminal tab) are counted apart.
func sessionCountLabel(_ sessions: [Session]) -> String {
    let bg = sessions.filter(\.isBackground).count
    return "\(sessions.count - bg) live" + (bg > 0 ? " · \(bg) background" : "")
}

struct Session: Identifiable {
    let id: String
    let pid: Int32
    let name: String
    /// The name other sessions message this one by (Claude Code's peer messaging).
    let peerName: String?
    let cwd: String
    let profile: Profile
    let status: SessionStatus
    let isBackground: Bool
    let statusSince: Date
    let ctxRemaining: Double?
}

/// Why a session is waiting: the Notification hook's message (exact, instant) and the tool call
/// it is blocked on (from the transcript).
struct WaitReason {
    let message: String?
    let pending: ToolAction?

    var summary: String {
        let call = pending.map { "\($0.tool): \($0.detail)" }
        switch (message, call) {
        case let (m?, c?): return "\(m) · \(c)"
        case let (m?, nil): return m
        case let (nil, c?): return c
        default: return "waiting for input"
        }
    }
}

enum WaitReasons {
    static var notifyDir: URL { Config.notifyDir }

    /// The hook's latest message for a session, only if it came during the current wait.
    static func hookMessage(for s: Session) -> String? {
        let url = notifyDir.appendingPathComponent("\(s.id).json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = (obj["ts"] as? NSNumber)?.doubleValue,
              ts >= s.statusSince.timeIntervalSince1970 - 5
        else { return nil }
        return obj["message"] as? String
    }

    static func reason(for s: Session, statusline: [String: [String: Any]]) -> WaitReason {
        let ctx = TranscriptReader.context(for: s, statusline: statusline, prompts: 0, replies: 0, actions: 0)
        return WaitReason(message: hookMessage(for: s), pending: ctx.pending)
    }
}

struct RateWindow {
    let usedPercent: Double
    let resetsAt: Date
}

struct AccountUsage {
    let profile: Profile
    let fiveHour: RateWindow?
    let sevenDay: RateWindow?
    let observedAt: Date
    /// Sum of `cost.total_cost_usd` over sessions active today. Each is that session's running total
    /// since it started (possibly days ago), at list price: an estimate, not a bill.
    let costToday: Double
}

enum SessionReader {
    static func readStatusline() -> [String: [String: Any]] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Config.statuslineDir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        return files
            .filter { $0.pathExtension == "json" }
            .reduce(into: [String: [String: Any]]()) { acc, url in
                guard let data = try? Data(contentsOf: url),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let sid = obj["session_id"] as? String
                else { return }
                acc[sid] = obj
            }
    }

    static func readSessions(statusline: [String: [String: Any]], includeStale: Bool = false) -> [Session] {
        let now = Date()
        let all = Config.sessionDirs.flatMap { profile, dir -> [Session] in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let fromFiles = files
                .filter { $0.pathExtension == "json" }
                .compactMap { url in parseSession(url: url, profile: profile, statusline: statusline) }
            guard let rows = AgentsList.rows(for: profile) else { return fromFiles }
            // Jobs run by Claude Code's background supervisor appear only in `claude agents`.
            let known = Set(fromFiles.map(\.id))
            let supervised = rows.compactMap { row -> Session? in
                guard row["pid"] == nil, let sid = row["sessionId"] as? String, !known.contains(sid) else { return nil }
                let cwd = row["cwd"] as? String ?? ""
                let ctx = (statusline[sid]?["context_window"] as? [String: Any])?["remaining_percentage"] as? NSNumber
                return Session(
                    id: sid, pid: 0,
                    name: row["name"] as? String ?? (cwd as NSString).lastPathComponent,
                    peerName: nil, cwd: cwd, profile: profile,
                    status: AgentsList.status(row), isBackground: true,
                    statusSince: Date(timeIntervalSince1970: ((row["startedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                    ctxRemaining: ctx?.doubleValue
                )
            }
            return fromFiles + supervised
        }
        // Closing a handed-off tab can leave the conversation running as a background fork with a
        // new session id; its continuation, "<name> (cont.)", is what identifies it as a leftover.
        let continued = Set(all.filter { !$0.isBackground }.map(\.name))
        return all
        .filter { s in
            includeStale || !(s.isBackground && (s.status == .idle || (s.pid == 0 && s.status == .waiting))
                && (now.timeIntervalSince(s.statusSince) > Config.staleBackgroundSeconds
                    || continued.contains(s.name + " (cont.)")))
        }
        .sorted { a, b in
            a.status.rank != b.status.rank ? a.status.rank < b.status.rank : a.name < b.name
        }
    }

    private static func parseSession(url: URL, profile: Profile, statusline: [String: [String: Any]]) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value,
              isAlive(pid)
        else { return nil }

        let sid = obj["sessionId"] as? String ?? url.lastPathComponent
        let ctx = (statusline[sid]?["context_window"] as? [String: Any])?["remaining_percentage"] as? NSNumber
        let sinceMs = (obj["statusUpdatedAt"] as? NSNumber ?? obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        let statuslineName = statusline[sid]?["session_name"] as? String
        let cwd = obj["cwd"] as? String ?? ""

        return Session(
            id: sid,
            pid: pid,
            name: statuslineName ?? obj["name"] as? String ?? (cwd as NSString).lastPathComponent,
            peerName: obj["name"] as? String,
            cwd: cwd,
            profile: profile,
            status: SessionStatus(rawValue: obj["status"] as? String ?? "") ?? .unknown,
            isBackground: (obj["kind"] as? String) == "bg",
            statusSince: Date(timeIntervalSince1970: sinceMs / 1000),
            ctxRemaining: ctx?.doubleValue
        )
    }

    /// Latest rate-limit snapshot per profile, taken from the freshest statusline write.
    static func readUsage(statusline: [String: [String: Any]]) -> [AccountUsage] {
        let latest = statusline.values.reduce(into: [Profile: [String: Any]]()) { acc, obj in
            guard let p = Config.profile(named: obj["widget_profile"] as? String ?? ""),
                  obj["rate_limits"] is [String: Any]
            else { return }
            let ts = (obj["widget_ts"] as? NSNumber)?.doubleValue ?? 0
            let prevTs = (acc[p]?["widget_ts"] as? NSNumber)?.doubleValue ?? -1
            if ts > prevTs { acc[p] = obj }
        }
        let costToday = statusline.values.reduce(into: [String: Double]()) { acc, obj in
            guard let p = obj["widget_profile"] as? String,
                  let ts = (obj["widget_ts"] as? NSNumber)?.doubleValue,
                  Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts)),
                  let c = ((obj["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue
            else { return }
            acc[p, default: 0] += c
        }
        return Config.profiles.compactMap { p in
            guard let obj = latest[p], let rl = obj["rate_limits"] as? [String: Any] else { return nil }
            return AccountUsage(
                profile: p,
                fiveHour: window(rl["five_hour"]),
                sevenDay: window(rl["seven_day"]),
                observedAt: Date(timeIntervalSince1970: (obj["widget_ts"] as? NSNumber)?.doubleValue ?? 0),
                costToday: costToday[p.name] ?? 0
            )
        }
    }

    private static func window(_ raw: Any?) -> RateWindow? {
        guard let d = raw as? [String: Any],
              let used = (d["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (d["resets_at"] as? NSNumber)?.doubleValue
        else { return nil }
        return RateWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

extension SessionReader {
    /// Live sessions matching a name part, session-id prefix, pid, folder name or peer name.
    static func match(_ query: String, in sessions: [Session]) -> [Session] {
        let q = query.lowercased()
        let exact = sessions.filter { $0.name.lowercased() == q || $0.peerName?.lowercased() == q }
        if !exact.isEmpty { return exact }
        return sessions.filter { s in
            s.name.lowercased().contains(q)
                || s.id.lowercased().hasPrefix(q)
                || String(s.pid) == q
                || (s.cwd as NSString).lastPathComponent.lowercased() == q
                || (s.peerName?.lowercased().contains(q) ?? false)
        }
    }
}
