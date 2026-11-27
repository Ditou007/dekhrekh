import Foundation

struct FailedJob {
    let name: String
    let step: String?
    let url: String
    let logTail: [String]
}

struct WaitResult {
    let repo: String
    let branch: String
    let sha: String
    let runs: [(name: String, conclusion: String, url: String)]
    let failures: [FailedJob]
    let timedOut: Bool

    var passed: Bool { !timedOut && failures.isEmpty && runs.allSatisfy { okConclusions.contains($0.conclusion) } }
}

private let okConclusions: Set<String> = ["success", "skipped", "neutral"]

extension CIClient {
    /// Polls until every run on the branch's newest commit has finished, or the timeout passes.
    /// `progress` gets one line whenever the set of unfinished runs changes.
    func waitForBranch(repo: RepoWatch, branch: String, timeout: TimeInterval, logLines: Int,
                       progress: (String) -> Void) async throws -> WaitResult {
        let deadline = Date().addingTimeInterval(timeout)
        var lastNote = ""

        while true {
            let url = Self.apiURL(repo, "/actions/runs", query: [
                URLQueryItem(name: "branch", value: branch), URLQueryItem(name: "per_page", value: "30"),
            ])
            let runs = try await getJSON(url, user: repo.ghUser)["workflow_runs"] as? [[String: Any]] ?? []
            let sha = runs.first?["head_sha"] as? String ?? ""
            // A re-triggered workflow leaves older runs on the same commit; the newest one per
            // workflow decides (runs arrive newest first).
            let current = runs.filter { $0["head_sha"] as? String == sha }
                .reduce(into: (seen: Set<String>(), runs: [[String: Any]]())) { acc, r in
                    let name = r["name"] as? String ?? ""
                    if acc.seen.insert(name).inserted { acc.runs.append(r) }
                }.runs
            let open = current.filter { $0["status"] as? String != "completed" }

            if !current.isEmpty && open.isEmpty {
                let summary = current.map { r in
                    (name: r["name"] as? String ?? "?", conclusion: r["conclusion"] as? String ?? "?",
                     url: r["html_url"] as? String ?? "")
                }
                var failures: [FailedJob] = []
                for r in current where !okConclusions.contains(r["conclusion"] as? String ?? "") {
                    guard let id = (r["id"] as? NSNumber)?.intValue else { continue }
                    failures += try await failedJobs(repo: repo, runId: id, logLines: logLines)
                }
                return WaitResult(repo: repo.label, branch: branch, sha: String(sha.prefix(7)),
                                  runs: summary, failures: failures, timedOut: false)
            }

            let note = current.isEmpty
                ? "no runs yet for \(branch)"
                : open.map { "\($0["name"] as? String ?? "?") \($0["status"] as? String ?? "")" }.joined(separator: ", ")
            if note != lastNote {
                progress("\(repo.label) \(branch) @\(sha.prefix(7)): \(note)")
                lastNote = note
            }
            if Date() > deadline {
                return WaitResult(repo: repo.label, branch: branch, sha: String(sha.prefix(7)),
                                  runs: [], failures: [], timedOut: true)
            }
            try await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    private func failedJobs(repo: RepoWatch, runId: Int, logLines: Int) async throws -> [FailedJob] {
        let url = Self.apiURL(repo, "/actions/runs/\(runId)/jobs", query: [URLQueryItem(name: "per_page", value: "100")])
        let jobs = try await getJSON(url, user: repo.ghUser)["jobs"]
            as? [[String: Any]] ?? []
        var out: [FailedJob] = []
        for j in jobs where failedConclusions.contains(j["conclusion"] as? String ?? "") {
            let step = (j["steps"] as? [[String: Any]] ?? [])
                .first { $0["conclusion"] as? String == "failure" }?["name"] as? String
            let id = (j["id"] as? NSNumber)?.intValue ?? 0
            out.append(FailedJob(name: j["name"] as? String ?? "?", step: step,
                                 url: j["html_url"] as? String ?? "",
                                 logTail: (try? await logTail(repo: repo, jobId: id, lines: logLines)) ?? []))
        }
        return out
    }

    /// The job log comes back as a redirect to a signed download URL; URLSession follows it.
    private func logTail(repo: RepoWatch, jobId: Int, lines: Int) async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(
            for: try authorizedRequest(Self.apiURL(repo, "/actions/jobs/\(jobId)/logs"), user: repo.ghUser))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let noise = try NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT[\d:.]+Z |\u001B\[[0-9;]*[A-Za-z]"#)
        let all = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let s = String(line)
                return noise.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        // The useful part ends at GitHub's error marker; everything after it is post-job cleanup.
        let end = all.lastIndex { $0.hasPrefix("##[error]") }.map { $0 + 1 } ?? all.count
        return Array(all[max(0, end - lines)..<end])
    }
}

/// The watched repo whose GitHub remote matches the git checkout at `cwd`.
func repoForFolder(_ cwd: String) -> RepoWatch? {
    guard let remotes = Git.remotes(at: cwd) else { return nil }
    return Config.repos.first { remotes.contains($0.fullName.lowercased()) }
}
