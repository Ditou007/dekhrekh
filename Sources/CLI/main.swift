import Foundation

let usage = """
usage: dekhrekh [sections...] [--json] [--all]
       dekhrekh show <session> [--json]

Prints what the Dekhrekh panel shows. Sections (default: all):
  sessions   live Claude Code sessions on every profile: status, context left, latest prompt
  usage      5h / 7d limits per profile, and when a limit will be hit at the current rate
  ci         latest CI state for the watched repos (config "repos")
  prs        open PRs: your review requested, yours failing / ready / waiting
  mem        this Mac's memory and the top apps
  server     the server card (config "server"), if one is set up

show <session>  what one session is doing: folder, branch, the user's recent prompts, its
                latest replies and recent tool calls. <session> matches a name (any part,
                case-insensitive), a session id prefix, a pid, or a folder name.

ci --stats [--runs=N]  queue wait and run time per job over the last N completed runs (default 15)
ci --wait [branch] [--repo=<label>] [--timeout=min] [--log-lines=n]
               wait for CI on the branch's newest commit (default: this folder's branch and repo);
               prints failing jobs, the failed step and the log tail. Exit 0 passed, 1 failed, 3 timed out.

handoff <session> [--force]  the session writes a handoff, then a new session (same folder, profile,
                 model, effort) opens in Ghostty and continues from it (the panel's "Hand off" button)
move <session> [--to=<profile>] [--force]  the session exits and the same conversation resumes on
                 another account of its group (most headroom first), in a new Ghostty tab
tell <session> "<message>"  type a message into that session's Ghostty tab (from your own terminal).
                 Agents: it refuses and prints the session's message name for the SendMessage tool.
restore [--dry-run]  reopen, in Ghostty, the Claude sessions open before the last restart
restart-check    is it safe to restart now? lists busy sessions and running subagents (exit 0 safe, 1 not)
snapshot         save the open sessions now (the panel also does it every minute)
claim "<note>"   record what this session is working on (repo, branch, files); --clear removes it
claims           every live session's folder, branch and claim

setup [--dry-run]  connect Claude Code to Dekhrekh: adds the status-line feed and the Notification
                 hook to each profile's settings.json (a backup is written first)
feed statusline [--then "<cmd>"]  (used by Claude Code) record the status-line JSON from stdin, then
                 print a status line, or pipe the same JSON to your own status-line command
feed notify      (used by Claude Code's Notification hook) record what a session is waiting on
config           show the config file path and what was loaded from it

--all also lists background sessions idle for over a day (hidden by default).
--json gives machine-readable output, for scripts and other Claude sessions.
"""

let allSections = ["sessions", "usage", "ci", "prs", "mem", "server"]
let args = CommandLine.arguments.dropFirst()
if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}
let asJSON = args.contains("--json")

switch args.first {
case "setup": runSetup(dryRun: args.contains("--dry-run"))
case "feed": runFeed(args: Array(args))
case "config": runConfig()
case "handoff": runHandoff(args: Array(args))
case "move": runMove(args: Array(args))
case "tell": runTell(args: Array(args))
case "restore": runRestore(dryRun: args.contains("--dry-run"))
case "restart-check": runRestartCheck(json: asJSON)
case "snapshot": runSnapshot()
case "claim": runClaim(args: Array(args))
case "claims": runClaims(json: asJSON)
case "show": runShow(query: args.dropFirst().filter { !$0.hasPrefix("-") }.joined(separator: " "), json: asJSON)
default: break
}

let picked = args.contains("--wait") ? ["ci"] : args.filter { !$0.hasPrefix("-") }.map { $0 == "home" ? "server" : $0 }
if let bad = picked.first(where: { !allSections.contains($0) }) {
    FileHandle.standardError.write("unknown section: \(bad)\n\n\(usage)\n".data(using: .utf8)!)
    exit(2)
}
let sections = picked.isEmpty ? allSections : Array(picked)

if args.contains("--wait") {
    await runWait(args: Array(args))
}

if args.contains("--stats") {
    let n = args.first { $0.hasPrefix("--runs=") }.flatMap { Int($0.dropFirst(7)) } ?? 15
    await runStats(limit: n, json: asJSON)
}
let now = Date()
let iso = ISO8601DateFormatter()

// MARK: gather

let statusline = SessionReader.readStatusline()
let showAll = args.contains("--all")
let sessions = sections.contains("sessions") ? SessionReader.readSessions(statusline: statusline, includeStale: showAll) : []
let lastPrompts = sessions.reduce(into: [String: String]()) { acc, s in
    acc[s.id] = TranscriptReader.context(for: s, statusline: statusline, prompts: 1, replies: 0, actions: 0).lastPrompt
}
let accounts = sections.contains("usage") ? SessionReader.readUsage(statusline: statusline) : []
let sysMem = sections.contains("mem") ? MemoryReader.system() : nil
let apps = sections.contains("mem") ? MemoryReader.topApps(limit: Config.topAppsLimit) : []
async let ciResults: [RepoCI] = sections.contains("ci") ? CIClient().fetchAll() : []
async let prResult: (prs: [PullRequest], errors: [String]) = sections.contains("prs") ? CIClient().fetchPRs() : ([], [])
let usageSamples = UsageHistory.read()
async let homeResult: Result<HomelabStatus, Error>? = sections.contains("server") ? HomelabClient.fetch() : nil
let ci = await ciResults
let home = await homeResult
let prs = await prResult

func eta(_ u: AccountUsage, _ window: UsageWindow) -> Date? {
    guard let w = u[window], w.resetsAt > now else { return nil }
    return UsageHistory.limitETA(profile: u.profile, window: window, current: w, samples: usageSamples, now: now)
}

// MARK: json

func windowJSON(_ w: RateWindow?, eta: Date?) -> Any {
    guard let w, w.resetsAt > now else { return NSNull() }
    return ["used_pct": w.usedPercent, "resets_at": iso.string(from: w.resetsAt),
            "limit_eta": eta.map { iso.string(from: $0) as Any } ?? NSNull()]
}

if asJSON {
    var out: [String: Any] = [:]
    if sections.contains("sessions") {
        out["sessions"] = sessions.map { s -> [String: Any] in
            [
                "name": s.name, "session_id": s.id, "pid": s.pid, "cwd": s.cwd,
                "message_name": s.peerName.map { $0 as Any } ?? NSNull(),
                "profile": s.profile.rawValue, "status": s.status.rawValue,
                "background": s.isBackground,
                "status_since": iso.string(from: s.statusSince),
                "context_remaining_pct": s.ctxRemaining.map { $0 as Any } ?? NSNull(),
                "last_prompt": lastPrompts[s.id].map { $0 as Any } ?? NSNull(),
                "claim": Claims.read(for: s.id).map { $0.note as Any } ?? NSNull(),
                "asks": Questions.pending(for: s, statusline: statusline).map { $0 as Any } ?? NSNull(),
                "waiting_on": s.status == .waiting
                    ? WaitReasons.reason(for: s, statusline: statusline).summary as Any : NSNull(),
            ]
        }
    }
    if sections.contains("usage") {
        out["usage"] = accounts.map { u -> [String: Any] in
            [
                "profile": u.profile.rawValue,
                "five_hour": windowJSON(u.fiveHour, eta: eta(u, .fiveHour)),
                "seven_day": windowJSON(u.sevenDay, eta: eta(u, .sevenDay)),
                "observed_at": iso.string(from: u.observedAt),
                "cost_today_usd": u.costToday,
            ]
        }
    }
    if sections.contains("ci") {
        out["ci"] = ci.map { r -> [String: Any] in
            [
                "repo": r.label, "running": r.running, "queued": r.queued,
                "error": r.error.map { $0 as Any } ?? NSNull(),
                "failures": r.failures.map {
                    ["workflow": $0.workflow, "branch": $0.branch, "actor": $0.actor,
                     "finished_at": iso.string(from: $0.finishedAt), "url": $0.url.absoluteString,
                     "scheduled": $0.scheduled]
                },
            ]
        }
    }
    if sections.contains("prs") {
        out["prs"] = prs.prs.map {
            ["repo": $0.repo, "number": $0.number, "title": $0.title, "author": $0.author,
             "state": $0.state.label, "needs_you": $0.state.needsYou, "url": $0.url.absoluteString,
             "updated_at": iso.string(from: $0.updatedAt)] as [String: Any]
        }
    }
    if let m = sysMem {
        out["mem"] = [
            "used_bytes": m.usedBytes, "total_bytes": m.totalBytes, "swap_used_bytes": m.swapUsedBytes,
            "top_apps": apps.map { ["name": $0.name, "bytes": $0.bytes, "processes": $0.processCount] },
        ] as [String: Any]
    }
    if let home {
        switch home {
        case .success(let h):
            out["server"] = [
                "mem_used_gb": h.memUsedGB, "mem_total_gb": h.memTotalGB, "load1": h.load1,
                "cores": h.cores, "temp_c": h.tempC.map { $0 as Any } ?? NSNull(),
                "disk_pct": h.diskPct, "uptime_h": h.uptimeH, "guests_down": h.guestsDown,
                "guests": h.guests.map {
                    ["id": $0.id, "name": $0.name, "type": $0.kind, "running": $0.running,
                     "mem_gb": $0.memGB, "maxmem_gb": $0.maxMemGB, "host_cpu_pct": $0.hostCpuPct]
                },
            ] as [String: Any]
        case .failure(let e):
            out["server"] = ["error": e.localizedDescription]
        }
    }
    let data = try JSONSerialization.data(withJSONObject: Frame.wrap(out), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

// MARK: text

let tty = isatty(STDOUT_FILENO) != 0
func paint(_ s: String, _ code: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func red(_ s: String) -> String { paint(s, "31") }
func amber(_ s: String) -> String { paint(s, "33") }
func green(_ s: String) -> String { paint(s, "32") }
func cyan(_ s: String) -> String { paint(s, "36") }
func dim(_ s: String) -> String { paint(s, "2") }
func header(_ s: String) { print(dim(s.uppercased())) }
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + "…" : s.padding(toLength: n, withPad: " ", startingAt: 0)
}

var blocks: [() -> Void] = []

if sections.contains("ci") {
    blocks.append {
        header("CI")
        for r in ci {
            let live = r.failures.filter { !$0.scheduled }.count
            let state = r.error.map { amber("? \($0)") }
                ?? (live > 0 ? red("\(live) failing") : (r.failures.isEmpty ? green("ok") : amber("ok, nightly failed")))
            let load = [r.running > 0 ? "\(r.running) running" : nil, r.queued > 0 ? "\(r.queued) queued" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            print("  \(pad(r.label, 10)) \(state)  \(dim(load))")
            for f in r.failures {
                if f.scheduled {
                    print("    \(amber("nightly")) \(f.branch)  \(dim(f.workflow + " · failed " + ago(f.finishedAt, now: now) + " ago, stays red until the next scheduled run ~" + clockTime(f.nextScheduledRun)))")
                    print("      \(dim(f.url.absoluteString))")
                    continue
                }
                print("    \(red("x")) \(f.branch)  \(dim(f.workflow + " · " + ago(f.finishedAt, now: now) + " ago"))")
                print("      \(dim(f.url.absoluteString))")
            }
        }
    }
}

if sections.contains("sessions") {
    blocks.append {
        header("Claude sessions (\(sessionCountLabel(sessions)))")
        for s in sessions {
            let status: String = {
                switch s.status {
                case .waiting: return amber("WAITING \(ago(s.statusSince, now: now))")
                case .busy, .shell: return cyan(s.status.rawValue)
                case .idle, .unknown: return dim(s.status.rawValue)
                }
            }()
            let ctx = s.ctxRemaining.map { r -> String in
                let t = "ctx \(Int(r.rounded()))%"
                if r <= Config.ctxCriticalRemaining { return red(t) }
                return r <= Config.ctxWarnRemaining ? amber(t) : dim(t)
            } ?? dim("ctx -")
            print("  \(pad(s.name, 34)) \(s.profile.tag)  \(pad(status, tty ? 21 : 12)) \(ctx)  \(dim("pid \(s.pid)\(s.peerName.map { Config.messageable(s) ? "  message name: \($0)" : "  other profile: no SendMessage" } ?? "")"))")
            if let q = Questions.pending(for: s, statusline: statusline) {
                print("    \(amber("asks you: " + oneLine(q, max: 110)))")
            }
            if s.status == .waiting {
                print("    \(amber("waiting on: " + oneLine(WaitReasons.reason(for: s, statusline: statusline).summary, max: 100)))")
            }
            let agents = Subagents.running(for: s, statusline: statusline)
            if !agents.isEmpty {
                print("    \(cyan("\(agents.count) subagent(s) running: " + agents.map(\.description).joined(separator: ", ")))")
            }
            if let c = Claims.read(for: s.id) {
                print("    \(cyan("working on: " + oneLine(c.note, max: 90)))")
            }
            if let p = lastPrompts[s.id] {
                print("    \(dim("> " + oneLine(p, max: 90)))")
            }
        }
    }
}

if sections.contains("usage") {
    blocks.append {
        header("Usage")
        for p in Config.profiles {
            guard let u = accounts.first(where: { $0.profile == p }) else {
                print("  \(pad(p.title, 12))  \(dim("no data yet"))")
                continue
            }
            func w(_ window: UsageWindow) -> String {
                let name = window.rawValue
                guard let x = u[window], x.resetsAt > now else { return "\(name) " + dim("reset") }
                let t = "\(name) \(Int(x.usedPercent))%"
                let colored = x.usedPercent >= Config.usageWarnUsed ? red(t) : t
                if let e = eta(u, window) { return colored + amber(" (limit ~\(clockTime(e)), resets \(until(x.resetsAt, now: now)))") }
                return colored + dim(" (resets \(until(x.resetsAt, now: now)))")
            }
            print("  \(pad(p.title, 12))  \(w(.fiveHour))   \(w(.sevenDay))   \(dim("seen \(ago(u.observedAt, now: now)) ago" + (u.costToday > 0 ? String(format: "   $%.2f in sessions active today (API prices)", u.costToday) : "")))")
        }
    }
}

if sections.contains("prs") {
    blocks.append {
        header("Pull requests (\(prs.prs.count) open)")
        for e in prs.errors { print("  \(amber("? " + e))") }
        if prs.prs.isEmpty && prs.errors.isEmpty { print("  \(dim("nothing open"))") }
        for pr in prs.prs {
            let label: String = {
                switch pr.state {
                case .failing: return red(pr.state.label)
                case .reviewRequested, .changesRequested: return amber(pr.state.label)
                case .readyToMerge: return green(pr.state.label)
                case .checksRunning: return cyan(pr.state.label)
                case .awaitingReview, .draft: return dim(pr.state.label)
                }
            }()
            print("  \(pad("\(pr.repo) #\(pr.number)", 14)) \(pad(label, tty ? 26 : 17)) \(oneLine(pr.title, max: 70))")
        }
    }
}

if let m = sysMem {
    blocks.append {
        let pct = Double(m.usedBytes) / Double(max(m.totalBytes, 1)) * 100
        let used = "\(formatBytes(m.usedBytes)) / \(formatBytes(m.totalBytes))"
        header("Memory (this Mac)")
        let mac = MacState.read()
        let hint = mac.restartReasons.isEmpty ? "" : amber("   restart suggested: " + mac.restartReasons.joined(separator: ", "))
        print("  up \(formatDuration(mac.uptime))   pressure \(mac.pressure == .normal ? mac.pressure.label : amber(mac.pressure.label))\(hint)")
        print("  \(pct >= Config.memoryWarnUsed ? amber(used) : used)   \(dim("swap \(formatBytes(m.swapUsedBytes))"))")
        for a in apps {
            let procs = a.processCount > 1 ? dim(" ×\(a.processCount)") : ""
            print("    \(pad(a.name, 28)) \(formatBytes(a.bytes).leftPad(6))\(procs)")
        }
    }
}

if let home {
    blocks.append {
        header(Config.server?.title ?? "Server")
        switch home {
        case .failure(let e):
            print("  \(amber("unreachable: \(e.localizedDescription)"))")
        case .success(let h):
            let temp = h.tempC.map { t -> String in
                let s = "\(Int(t))°C"
                if t >= (Config.server?.tempBadC ?? 90) { return red(s) }
                return t >= (Config.server?.tempWarnC ?? 80) ? amber(s) : s
            } ?? "-"
            let mem = String(format: "%.1f / %.0fG", h.memUsedGB, h.memTotalGB)
            print("  mem \(mem)   load \(String(format: "%.1f", h.load1)) / \(h.cores)   temp \(temp)   \(dim(String(format: "disk %.0f%%  up %dd", h.diskPct, Int(h.uptimeH / 24))))")
            if !h.guestsDown.isEmpty { print("  \(red("down: " + h.guestsDown.joined(separator: ", ")))") }
            for g in h.guests {
                let mark = g.running ? green("●") : dim("○")
                print("    \(mark) \(pad(g.name, 16)) \(String(format: "%5.1f/%-4.0fG  cpu %4.1f%%", g.memGB, g.maxMemGB, g.hostCpuPct))")
            }
        }
    }
}

Frame.open()
for (i, block) in blocks.enumerated() {
    if i > 0 { print("") }
    block()
}
Frame.close()

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
