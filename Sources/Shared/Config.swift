import Foundation

/// A GitHub repo whose CI and pull requests are watched.
struct RepoWatch {
    let label: String
    let fullName: String
    /// GitHub login to query as (`gh auth token --user`); also whose PRs and review requests count.
    let ghUser: String
    /// When empty, every run counts. Otherwise only runs by these actors or on `branches`.
    let actors: Set<String>
    let branches: Set<String>
}

/// One Claude Code configuration directory (an account). Most people have one.
struct Profile: Hashable {
    /// Stable id, written into the status-line feed.
    let name: String
    /// Shown in the usage section; defaults to `name`.
    let title: String
    /// Short label shown on each session row; empty hides it.
    let tag: String
    /// The Claude Code config dir: `~/.claude`, or whatever `CLAUDE_CONFIG_DIR` points at.
    let claudeDir: URL
    /// Shell command that starts Claude Code with this profile (handoff, restore, move).
    let launch: String
    /// Profiles with the same group can take over each other's sessions ("Continue on ..."):
    /// two work accounts, say, but never a work session onto a personal one. Empty is a group too.
    let group: String

    var rawValue: String { name }
    var sessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
}

/// The optional server card: any URL returning the JSON described in README ("Server card").
struct ServerCard {
    let title: String
    let url: URL
    let coresFallback: Int
    let tempWarnC: Double
    let tempBadC: Double
    /// Guests stopped on purpose; a stopped guest here is not reported as down.
    let parked: Set<String>
}

/// Settings read from `~/.config/dekhrekh/config.json` (or `$DEKHREKH_CONFIG`). Every key is optional.
struct UserConfig {
    var profiles: [Profile]
    var repos: [RepoWatch]
    var server: ServerCard?
    var stateDir: URL
    var ghPath: String
    var loadError: String?

    static let path: URL = {
        if let p = ProcessInfo.processInfo.environment["DEKHREKH_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: expand(p)) }
        return Config.home.appendingPathComponent(".config/dekhrekh/config.json")
    }()

    static func expand(_ p: String) -> String {
        p == "~" ? Config.home.path : (p.hasPrefix("~/") ? Config.home.path + p.dropFirst(1) : p)
    }

    static func load() -> UserConfig {
        var obj: [String: Any] = [:]
        var error: String?
        if let data = try? Data(contentsOf: path) {
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { obj = o }
            else { error = "\(path.path) is not valid JSON; using defaults" }
        }
        let gh = (obj["ghPath"] as? String).map(expand)
            ?? ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "gh"
        return UserConfig(
            profiles: parseProfiles(obj["profiles"]),
            repos: parseRepos(obj["repos"], ghPath: gh),
            server: parseServer(obj["server"]),
            stateDir: URL(fileURLWithPath: expand(obj["stateDir"] as? String ?? "~/.claude/state/dekhrekh")),
            ghPath: gh,
            loadError: error
        )
    }

    private static func parseProfiles(_ raw: Any?) -> [Profile] {
        let list = (raw as? [[String: Any]] ?? []).compactMap { p -> Profile? in
            guard let name = p["name"] as? String, let dir = p["claudeDir"] as? String else { return nil }
            return Profile(name: name, title: p["title"] as? String ?? name, tag: p["tag"] as? String ?? "",
                           claudeDir: URL(fileURLWithPath: expand(dir)), launch: p["launch"] as? String ?? "claude",
                           group: p["group"] as? String ?? "")
        }
        if !list.isEmpty { return list }
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map(expand) ?? Config.home.appendingPathComponent(".claude").path
        return [Profile(name: "default", title: "Claude Code", tag: "", claudeDir: URL(fileURLWithPath: dir), launch: "claude", group: "")]
    }

    private static func parseRepos(_ raw: Any?, ghPath: String) -> [RepoWatch] {
        (raw as? [[String: Any]] ?? []).compactMap { r in
            guard let full = r["repo"] as? String, full.contains("/") else { return nil }
            return RepoWatch(
                label: r["label"] as? String ?? String(full.split(separator: "/").last!),
                fullName: full,
                ghUser: r["ghUser"] as? String ?? activeLogin(ghPath),
                actors: Set(r["actors"] as? [String] ?? []),
                branches: Set(r["branches"] as? [String] ?? [])
            )
        }
    }

    private static func parseServer(_ raw: Any?) -> ServerCard? {
        guard let s = raw as? [String: Any], let u = (s["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return ServerCard(
            title: s["title"] as? String ?? "Server",
            url: u,
            coresFallback: s["cores"] as? Int ?? 1,
            tempWarnC: (s["tempWarnC"] as? NSNumber)?.doubleValue ?? 80,
            tempBadC: (s["tempBadC"] as? NSNumber)?.doubleValue ?? 90,
            parked: Set(s["parked"] as? [String] ?? [])
        )
    }

    /// The login `gh` is signed in as, for repos that do not name one. Looked up once.
    private static var cachedLogin: String?
    private static func activeLogin(_ gh: String) -> String {
        if let l = cachedLogin { return l }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gh)
        proc.arguments = ["api", "user", "--jq", ".login"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let login = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cachedLogin = login
        return login
    }
}

enum Config {
    static let appName = "Dekhrekh"
    static let cli = "dekhrekh"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let user = UserConfig.load()

    static var profiles: [Profile] { user.profiles }
    static var sessionDirs: [(Profile, URL)] { user.profiles.map { ($0, $0.sessionsDir) } }
    static var repos: [RepoWatch] { user.repos }
    static var ghPath: String { user.ghPath }
    static var server: ServerCard? { user.server }

    static var stateDir: URL { user.stateDir }
    static var statuslineDir: URL { stateDir.appendingPathComponent("statusline") }
    static var notifyDir: URL { stateDir.appendingPathComponent("notify") }

    /// The profile a feed write belongs to: the one whose dir matches `CLAUDE_CONFIG_DIR`, else the first.
    static func profile(forConfigDir dir: String?) -> Profile {
        let want = URL(fileURLWithPath: UserConfig.expand(dir ?? home.appendingPathComponent(".claude").path)).resolvingSymlinksInPath().path
        return profiles.first { $0.claudeDir.resolvingSymlinksInPath().path == want } ?? profiles[0]
    }

    static func profile(named name: String) -> Profile? { profiles.first { $0.name == name } }

    /// The profile of the Claude session running this command; nil from a plain terminal.
    /// Claude Code only finds message peers within its own config dir, so SendMessage cannot cross profiles.
    static var callerProfile: Profile? {
        let env = ProcessInfo.processInfo.environment
        return env["CLAUDECODE"] == nil ? nil : profile(forConfigDir: env["CLAUDE_CONFIG_DIR"])
    }

    static func messageable(_ s: Session) -> Bool { callerProfile.map { $0 == s.profile } ?? true }

    static let sessionPollSeconds: TimeInterval = 2
    /// Background sessions idle longer than this are leftovers, not work in progress; hidden by default.
    static let staleBackgroundSeconds: TimeInterval = 24 * 3600
    static let ciPollSeconds: TimeInterval = 60
    static let ciLookbackHours: Double = 24

    static let ctxWarnRemaining = 40.0
    static let ctxCriticalRemaining = 20.0
    static let usageWarnUsed = 80.0
    static let memoryWarnUsed = 85.0
    static let topAppsLimit = 8
    static let swapWarnBytes: UInt64 = 8 * 1_073_741_824
    /// Uptime past which a restart is suggested, when the Mac is also under memory strain.
    static let restartUptimeDays: TimeInterval = 14
    /// The session snapshot is rewritten every N session polls (2 s each).
    static let snapshotEveryTicks = 30
    static let dockerVMName = "Docker VM"
    static let prPollSeconds: TimeInterval = 120
    static let prRowsLimit = 6
    /// Top-apps scan runs every N session polls, and only while the memory list is open.
    static let topAppsEveryTicks = 3
    /// The Docker VM check walks every process; every 5 polls (10 s) is plenty.
    static let processScanEveryTicks = 5
    static let serverPollSeconds: TimeInterval = 30

    /// Argument fragments that name a JVM's job; anything unmatched stays "java".
    static let javaRoles: [String: String] = [
        "GradleDaemon": "Gradle daemon",
        "gradle-wrapper.jar": "Gradle build",
        "KotlinCompileDaemon": "Kotlin daemon",
        "kotlin-compiler-embeddable": "Kotlin daemon",
        "sonarlint": "SonarLint (editor)",
    ]

    /// Path fragments whose process name is unhelpful (version numbers, system XPC ids).
    static let processAliases: [String: String] = [
        "/.local/share/claude/versions/": "Claude Code",
        "com.apple.Virtualization.VirtualMachine": "Docker VM",
    ]

    /// Background opacity, no blur, so whatever is behind the panel stays readable.
    static let panelOpacity = 0.92
    static let iconSymbol = "eye.fill"
    /// Gap kept between the panel and the screen edges; the header is never scrolled away.
    static let panelScreenMargin: CGFloat = 12
    static let panelHeaderHeight: CGFloat = 42

    static let terminalBundleId = "com.mitchellh.ghostty"
}
