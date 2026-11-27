import Foundation

/// `dekhrekh feed statusline [--then "<cmd>"]` and `dekhrekh feed notify`: Claude Code calls these.
/// They must never fail loudly: a broken feed would break the user's status line or hook.
func runFeed(args: [String]) -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    let sid = obj["session_id"] as? String ?? ""
    switch args.dropFirst().first {
    case "statusline":
        if !sid.isEmpty {
            var rec = obj
            rec["widget_profile"] = Config.profile(forConfigDir: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]).name
            rec["widget_ts"] = Date().timeIntervalSince1970
            writeAtomically(rec, to: Config.statuslineDir.appendingPathComponent("\(sid).json"))
        }
        if let i = args.firstIndex(of: "--then"), i + 1 < args.count {
            exit(passThrough(input, to: args[i + 1]))
        }
        let model = (obj["model"] as? [String: Any])?["display_name"] as? String ?? "Claude"
        let left = ((obj["context_window"] as? [String: Any])?["remaining_percentage"] as? NSNumber)?.intValue
        print(left.map { "\(model) · \($0)% context left" } ?? model)
        exit(0)
    case "notify":
        if !sid.isEmpty {
            writeAtomically(["message": obj["message"] ?? NSNull(), "notification_type": obj["notification_type"] ?? NSNull(),
                             "ts": Date().timeIntervalSince1970],
                            to: Config.notifyDir.appendingPathComponent("\(sid).json"))
        }
        exit(0)
    default:
        FileHandle.standardError.write("usage: \(Config.cli) feed statusline [--then \"<cmd>\"] | feed notify\n".data(using: .utf8)!)
        exit(2)
    }
}

private func writeAtomically(_ obj: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

/// Runs the user's own status-line command with the same JSON on stdin, so wrapping it changes nothing they see.
private func passThrough(_ input: Data, to command: String) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", command]
    let stdin = Pipe()
    proc.standardInput = stdin
    guard (try? proc.run()) != nil else { return 0 }
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    proc.waitUntilExit()
    return proc.terminationStatus
}

private let statusRefreshSeconds = 30

/// `dekhrekh setup [--dry-run]`: adds the two feeds to every profile's settings.json, keeping what is there.
func runSetup(dryRun: Bool) -> Never {
    let cli = installedCLIPath()
    var seen = Set<String>()
    for p in Config.profiles {
        let file = p.claudeDir.appendingPathComponent("settings.json")
        let real = file.resolvingSymlinksInPath().path
        guard seen.insert(real).inserted else { continue }
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                print("\(file.path): not valid JSON, left alone"); continue
            }
            settings = o
        }
        var changes: [String] = []

        let status = settings["statusLine"] as? [String: Any]
        let current = status?["command"] as? String
        if let current, current.contains("feed statusline") {
            // already connected
        } else if let current, !current.isEmpty {
            settings["statusLine"] = (status ?? [:]).merging(["type": "command", "command": "\(cli) feed statusline --then \(Shell.quote(current))"]) { $1 }
            changes.append("status line: your command now runs through \(Config.cli) (same output)")
        } else {
            settings["statusLine"] = ["type": "command", "command": "\(cli) feed statusline"]
            changes.append("status line: added (shows model and context left)")
        }

        // Without a timer the status line only runs on events, so idle sessions stop reporting usage.
        if var sl = settings["statusLine"] as? [String: Any], sl["refreshInterval"] == nil {
            sl["refreshInterval"] = statusRefreshSeconds
            settings["statusLine"] = sl
            changes.append("status line: refreshes every \(statusRefreshSeconds) s, so idle sessions keep reporting usage")
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var notification = hooks["Notification"] as? [[String: Any]] ?? []
        let hasNotify = notification.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("feed notify") }
        }
        if !hasNotify {
            notification.append(["hooks": [["type": "command", "command": "\(cli) feed notify", "timeout": 5]]])
            hooks["Notification"] = notification
            settings["hooks"] = hooks
            changes.append("Notification hook: added (records what a session is waiting on)")
        }

        guard !changes.isEmpty else { print("\(file.path): already set up"); continue }
        print("\(file.path):")
        changes.forEach { print("  - \($0)") }
        if dryRun { continue }
        if FileManager.default.fileExists(atPath: real) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try? FileManager.default.copyItem(atPath: real, toPath: real + ".bak-\(Config.cli)-\(stamp)")
            print("  backup: \(real).bak-\(Config.cli)-\(stamp)")
        }
        guard let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            print("  could not encode settings; nothing written"); continue
        }
        do {
            try FileManager.default.createDirectory(atPath: (real as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try out.write(to: URL(fileURLWithPath: real), options: .atomic)
        } catch {
            print("  write failed: \(error.localizedDescription)")
        }
    }
    print(dryRun ? "Dry run: nothing written." : "Done. Sessions pick this up on their next status-line refresh; restart open sessions for the hook.")
    exit(0)
}

/// `dekhrekh config`: where the config lives and what it resolved to.
func runConfig() -> Never {
    let u = Config.user
    let exists = FileManager.default.fileExists(atPath: UserConfig.path.path)
    print("config   \(UserConfig.path.path)\(exists ? "" : "  (not found: using defaults)")")
    if let e = u.loadError { print("error    \(e)") }
    print("state    \(u.stateDir.path)")
    print("gh       \(u.ghPath)")
    for p in u.profiles { print("profile  \(p.name)  \(p.claudeDir.path)  launch: \(p.launch)\(p.tag.isEmpty ? "" : "  tag: \(p.tag)")\(p.group.isEmpty ? "" : "  group: \(p.group)")") }
    if u.repos.isEmpty { print("repos    none (CI and PR sections hidden)") }
    for r in u.repos { print("repo     \(r.label)  \(r.fullName)  as \(r.ghUser.isEmpty ? "?" : r.ghUser)") }
    print("server   \(u.server.map { "\($0.title)  \($0.url.absoluteString)" } ?? "none (card hidden)")")
    exit(0)
}

private func installedCLIPath() -> String {
    let linked = Config.home.appendingPathComponent(".local/bin/\(Config.cli)").path
    if FileManager.default.isExecutableFile(atPath: linked) { return linked }
    let arg0 = CommandLine.arguments[0]
    if arg0.contains("/") { return URL(fileURLWithPath: arg0).standardizedFileURL.path }
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return dirs.map { "\($0)/\(arg0)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? arg0
}
