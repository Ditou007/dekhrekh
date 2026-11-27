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

    static func reason(for s: Session, statusline: StatusFeeds) -> WaitReason {
        let ctx = TranscriptReader.context(for: s, statusline: statusline, prompts: 0, replies: 0, actions: 0)
        return WaitReason(message: hookMessage(for: s), pending: ctx.pending)
    }
}

struct RateWindow {
    let usedPercent: Double
    let resetsAt: Date
}

/// Claude's two rate-limit windows. The raw value is the label shown and stored in usage history.
enum UsageWindow: String, CaseIterable {
    case fiveHour = "5h"
    case sevenDay = "7d"
}

struct AccountUsage {
    let profile: Profile
    let fiveHour: RateWindow?
    let sevenDay: RateWindow?
    let observedAt: Date
    /// Sum of `cost.total_cost_usd` over sessions active today. Each is that session's running total
    /// since it started (possibly days ago), at list price: an estimate, not a bill.
    let costToday: Double

    subscript(window: UsageWindow) -> RateWindow? {
        switch window {
        case .fiveHour: return fiveHour
        case .sevenDay: return sevenDay
        }
    }
}

enum SessionReader {
    static func readStatusline() -> StatusFeeds {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Config.statuslineDir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        return files
            .filter { $0.pathExtension == "json" }
            .reduce(into: StatusFeeds()) { acc, url in
                guard let data = try? Data(contentsOf: url), let feed = StatusFeed.decode(data) else { return }
                acc[feed.sessionId] = feed
            }
    }

    static func readSessions(statusline: StatusFeeds, includeStale: Bool = false) -> [Session] {
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
                return Session(
                    id: sid, pid: 0,
                    name: row["name"] as? String ?? (cwd as NSString).lastPathComponent,
                    peerName: nil, cwd: cwd, profile: profile,
                    status: AgentsList.status(row), isBackground: true,
                    statusSince: Date(timeIntervalSince1970: ((row["startedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                    ctxRemaining: statusline[sid]?.contextWindow?.remainingPercentage
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

    private static func parseSession(url: URL, profile: Profile, statusline: StatusFeeds) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value,
              isAlive(pid)
        else { return nil }

        let sid = obj["sessionId"] as? String ?? url.lastPathComponent
        let sinceMs = (obj["statusUpdatedAt"] as? NSNumber ?? obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        let statuslineName = statusline[sid]?.sessionName
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
            ctxRemaining: statusline[sid]?.contextWindow?.remainingPercentage
        )
    }

    /// Latest rate-limit snapshot per profile, taken from the freshest statusline write.
    static func readUsage(statusline: StatusFeeds) -> [AccountUsage] {
        let latest = statusline.values.reduce(into: [Profile: StatusFeed]()) { acc, feed in
            guard let p = Config.profile(named: feed.widgetProfile ?? ""), feed.rateLimits != nil else { return }
            if (feed.widgetTs ?? 0) > (acc[p]?.widgetTs ?? -1) { acc[p] = feed }
        }
        let costToday = statusline.values.reduce(into: [String: Double]()) { acc, feed in
            guard let p = feed.widgetProfile, let ts = feed.widgetTs,
                  Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts)),
                  let c = feed.cost?.totalCostUsd
            else { return }
            acc[p, default: 0] += c
        }
        return Config.profiles.compactMap { p in
            guard let feed = latest[p], let rl = feed.rateLimits else { return nil }
            return AccountUsage(
                profile: p,
                fiveHour: rl.fiveHour?.rateWindow,
                sevenDay: rl.sevenDay?.rateWindow,
                observedAt: Date(timeIntervalSince1970: feed.widgetTs ?? 0),
                costToday: costToday[p.name] ?? 0
            )
        }
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
