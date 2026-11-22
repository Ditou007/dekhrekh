import Foundation

/// `claude agents --json`: Claude Code's documented list of sessions, including background jobs
/// run by its supervisor, which have no session file of their own. Nil when the command is missing
/// or fails (older Claude Code), so callers fall back to the session files.
enum AgentsList {
    private static let cacheSeconds: TimeInterval = 3
    private static var cache: [String: (at: Date, rows: [[String: Any]]?)] = [:]
    private static let lock = NSLock()

    static let claudePath: String? = {
        if let p = ProcessInfo.processInfo.environment["DEKHREKH_CLAUDE"], !p.isEmpty { return p }
        let candidates = [Config.home.appendingPathComponent(".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func rows(for profile: Profile) -> [[String: Any]]? {
        lock.lock()
        if let hit = cache[profile.name], Date().timeIntervalSince(hit.at) < cacheSeconds { lock.unlock(); return hit.rows }
        lock.unlock()
        let rows = run(profile)
        lock.lock()
        cache[profile.name] = (Date(), rows)
        lock.unlock()
        return rows
    }

    private static func run(_ profile: Profile) -> [[String: Any]]? {
        guard let claude = claudePath else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = ["agents", "--json"]
        var env = ProcessInfo.processInfo.environment
        let defaultDir = Config.home.appendingPathComponent(".claude").resolvingSymlinksInPath().path
        if profile.claudeDir.resolvingSymlinksInPath().path != defaultDir { env["CLAUDE_CONFIG_DIR"] = profile.claudeDir.path }
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Background jobs report `state`; interactive sessions report `status`.
    static func status(_ row: [String: Any]) -> SessionStatus {
        if let s = row["status"] as? String, let st = SessionStatus(rawValue: s) { return st }
        switch row["state"] as? String {
        case "blocked", "needs_input", "waiting": return .waiting
        case "working", "running", "busy": return .busy
        case "idle", "done", "completed", "failed", "stopped": return .idle
        default: return .unknown
        }
    }
}
