import Foundation

// A dependency-free test runner: XCTest and Swift Testing are not part of every Command Line Tools
// install, and the app builds without Xcode. `./test.sh` compiles this with Sources/Shared.

var failures = 0
var checks = 0

func check(_ ok: @autoclosure () -> Bool, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !ok() {
        failures += 1
        print("FAIL \(file):\(line)  \(what)")
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
    check(got == want, "\(what): got \(got), want \(want)", file: file, line: line)
}

let profile = Profile(name: "work", title: "Work", tag: "", claudeDir: URL(fileURLWithPath: "/tmp/claude"),
                      launch: "claude", group: "")

func session(_ name: String, id: String = UUID().uuidString, pid: Int32 = 1, cwd: String = "/tmp/x",
             peer: String? = nil) -> Session {
    Session(id: id, pid: pid, name: name, peerName: peer, cwd: cwd, profile: profile, status: .idle,
            isBackground: false, statusSince: Date(), ctxRemaining: nil)
}

// MARK: Shell

do {
    let r = Shell.run("/bin/echo", ["hello"])
    equal(r?.text, "hello", "echo output")
    equal(r?.ok, true, "echo exit status")

    // More than a pipe buffer (64 KB): the old read-after-wait pattern deadlocked here.
    let big = Shell.run("/bin/sh", ["-c", "head -c 500000 /dev/zero"], timeout: 5)
    equal(big?.stdout.count, 500_000, "large output is read in full")

    let started = Date()
    let slow = Shell.run("/bin/sleep", ["5"], timeout: 0.5)
    check(slow == nil, "a command past its timeout returns nil")
    check(Date().timeIntervalSince(started) < 3, "the timeout is enforced")

    check(Shell.run("/nonexistent/gh", ["api", "user"]) == nil, "a missing binary returns nil instead of hanging")
    equal(Shell.run("/usr/bin/false", [])?.ok, false, "non-zero exit is reported")

    for s in ["plain", "it's", "a b", "$(rm -rf /)", "[1m]", "\"q\""] {
        equal(Shell.run("/bin/sh", ["-c", "printf %s " + Shell.quote(s)])?.text, s, "quote round-trips \(s)")
    }
}

// MARK: Config

equal(UserConfig.repoName("cli/cli"), "cli", "owner/name")
equal(UserConfig.repoName("Homebrew/homebrew-core.git"), "homebrew-core.git", "dots and dashes")
equal(UserConfig.repoName("/"), nil, "empty parts")
equal(UserConfig.repoName("a/b/c"), nil, "three parts")
equal(UserConfig.repoName("bad name/x"), nil, "space")
equal(UserConfig.repoName("noslash"), nil, "no slash")

// MARK: Questions

equal(Questions.question(in: "Done. Should I open the PR?"), "Should I open the PR?", "trailing question")
equal(Questions.question(in: "All tests pass."), nil, "no question")
equal(Questions.question(in: "Why did it fail? Because the cache was stale. " + String(repeating: "More detail. ", count: 20)),
      nil, "a question followed by a long answer is rhetorical")

// MARK: Transcript

check(TranscriptReader.isHumanPrompt("fix the build"), "typed prompt")
check(TranscriptReader.isHumanPrompt("<pasted_content>log</pasted_content>"), "a paste is the user's")
check(!TranscriptReader.isHumanPrompt("<system-reminder>x</system-reminder>"), "harness wrapper")
check(!TranscriptReader.isHumanPrompt("Another Claude session sent a message: hi"), "relayed message")
check(!TranscriptReader.isHumanPrompt("   "), "blank")

// MARK: Usage forecast

do {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let resets = now.addingTimeInterval(3 * 3600)
    let sample = UsageHistory.Sample(profile: "work", window: UsageWindow.fiveHour.rawValue,
                                     resetsAt: resets.timeIntervalSince1970, used: 60,
                                     at: now.timeIntervalSince1970 - 1200)
    // 10 points in 20 minutes; 30 points left: one hour.
    let eta = UsageHistory.limitETA(profile: profile, window: .fiveHour,
                                    current: RateWindow(usedPercent: 70, resetsAt: resets), samples: [sample], now: now)
    equal(eta.map { Int($0.timeIntervalSince(now)) }, 3600, "linear forecast")

    let early = UsageHistory.limitETA(profile: profile, window: .fiveHour,
                                      current: RateWindow(usedPercent: 40, resetsAt: resets), samples: [sample], now: now)
    check(early == nil, "no forecast below half used")

    let soonReset = now.addingTimeInterval(1800)
    let resetFirst = UsageHistory.limitETA(
        profile: profile, window: .fiveHour, current: RateWindow(usedPercent: 70, resetsAt: soonReset),
        samples: [UsageHistory.Sample(profile: "work", window: "5h", resetsAt: soonReset.timeIntervalSince1970,
                                      used: 60, at: now.timeIntervalSince1970 - 1200)],
        now: now)
    check(resetFirst == nil, "no forecast when the window resets first")
}

// MARK: Pull requests

equal(PRState.of(mine: false, draft: false, checks: nil, reviewDecision: nil, reviewRequested: true),
      .reviewRequested, "review asked of me")
equal(PRState.of(mine: false, draft: false, checks: "FAILURE", reviewDecision: nil, reviewRequested: false),
      nil, "someone else's PR without a request")
equal(PRState.of(mine: true, draft: true, checks: "FAILURE", reviewDecision: nil, reviewRequested: false),
      .draft, "a draft stays a draft")
equal(PRState.of(mine: true, draft: false, checks: "ERROR", reviewDecision: "APPROVED", reviewRequested: false),
      .failing, "failing checks beat approval")
equal(PRState.of(mine: true, draft: false, checks: "PENDING", reviewDecision: nil, reviewRequested: false),
      .checksRunning, "checks running")
equal(PRState.of(mine: true, draft: false, checks: "SUCCESS", reviewDecision: "APPROVED", reviewRequested: false),
      .readyToMerge, "approved and green")
equal(PRState.of(mine: true, draft: false, checks: "SUCCESS", reviewDecision: "CHANGES_REQUESTED", reviewRequested: false),
      .changesRequested, "changes requested")
equal(PRState.of(mine: true, draft: false, checks: nil, reviewDecision: nil, reviewRequested: false),
      .awaitingReview, "no decision yet")

// MARK: CI summary

do {
    let repo = RepoWatch(label: "app", fullName: "o/app", configuredUser: "me", actors: [], branches: [])
    func run(_ id: Int, _ name: String, branch: String, conclusion: String?, status: String = "completed",
             event: String = "push") -> [String: Any] {
        ["id": id, "name": name, "head_branch": branch, "status": status, "conclusion": conclusion ?? NSNull(),
         "event": event, "html_url": "https://github.com/o/app/actions/runs/\(id)",
         "created_at": "2026-11-27T10:00:00Z", "updated_at": "2026-11-27T10:05:00Z", "actor": ["login": "me"]]
    }
    // Newest first, as GitHub returns them.
    let runs = [
        run(5, "test", branch: "main", conclusion: "success"),
        run(4, "test", branch: "main", conclusion: "failure"),
        run(3, "lint", branch: "main", conclusion: "failure"),
        run(2, "test", branch: "old-pr", conclusion: "failure"),
        run(1, "nightly", branch: "main", conclusion: "timed_out", event: "schedule"),
        run(6, "test", branch: "feature", conclusion: nil, status: "in_progress"),
        run(7, "test", branch: "next", conclusion: nil, status: "queued"),
    ]
    let ci = CIClient().summarise(repo: repo, runs: runs, live: ["main", "feature", "next"])
    equal(ci.failures.map(\.id).sorted(), [1, 3], "only the latest run per workflow and branch, on live branches")
    equal(ci.failures.first { $0.id == 1 }?.scheduled, true, "nightly runs are marked scheduled")
    equal(ci.running, 1, "running")
    equal(ci.queued, 1, "queued")

    let unknownBranches = CIClient().summarise(repo: repo, runs: runs, live: nil)
    equal(unknownBranches.failures.map(\.id).sorted(), [1, 2, 3], "nothing hidden when branches are unknown")
}

// MARK: Status feed

do {
    let json = """
    {"session_id":"abc","session_name":"web","transcript_path":"/tmp/t.jsonl",
     "context_window":{"remaining_percentage":42},
     "rate_limits":{"five_hour":{"used_percentage":71.5,"resets_at":1800000000},"seven_day":{"used_percentage":12}},
     "cost":{"total_cost_usd":3.25},"model":{"id":"claude-opus-5-5"},"effort":{"level":"high"},
     "widget_profile":"work","widget_ts":1799990000,"unknown_field":true}
    """
    let feed = StatusFeed.decode(Data(json.utf8))
    equal(feed?.sessionId, "abc", "session id")
    equal(feed?.contextWindow?.remainingPercentage, 42, "an integer decodes as Double")
    equal(feed?.rateLimits?.fiveHour?.rateWindow?.usedPercent, 71.5, "five-hour window")
    check(feed?.rateLimits?.sevenDay?.rateWindow == nil, "a window without resets_at is dropped")
    equal(feed?.model?.id, "claude-opus-5-5", "model")
    equal(feed?.widgetProfile, "work", "profile added by the feed")
    check(StatusFeed.decode(Data("{}".utf8)) == nil, "no session id, no feed")
}

// MARK: Session matching

do {
    let web = session("web", id: "aaaa1111", pid: 101, cwd: "/src/web")
    let admin = session("web-admin", id: "bbbb2222", pid: 102, cwd: "/src/admin", peer: "admin-peer")
    let all = [web, admin]
    equal(SessionReader.match("web", in: all).map(\.id), ["aaaa1111"], "an exact name wins over a substring")
    equal(SessionReader.match("adm", in: all).map(\.id), ["bbbb2222"], "name part")
    equal(SessionReader.match("bbbb", in: all).map(\.id), ["bbbb2222"], "id prefix")
    equal(SessionReader.match("101", in: all).map(\.id), ["aaaa1111"], "pid")
    equal(SessionReader.match("admin", in: all).map(\.id), ["bbbb2222"], "folder name")
    equal(SessionReader.match("nothing", in: all).count, 0, "no match")
}

print(failures == 0 ? "ok: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
