import Foundation

struct FailedRun: Identifiable {
    let id: Int
    let workflow: String
    let branch: String
    let actor: String
    let finishedAt: Date
    let url: URL
    /// Scheduled (nightly) runs: a failure stays until the next scheduled run, so it is shown
    /// as a notice rather than an alarm.
    let scheduled: Bool
    let createdAt: Date

    /// When the same schedule should fire again (scheduled runs repeat daily here).
    var nextScheduledRun: Date { createdAt.addingTimeInterval(24 * 3600) }
}

struct RepoCI: Identifiable {
    var id: String { label }
    let label: String
    let failures: [FailedRun]
    let running: Int
    let queued: Int
    let error: String?
    let checkedAt: Date
}

private let failedConclusions: Set<String> = ["failure", "timed_out", "startup_failure"]
private let queuedStatuses: Set<String> = ["queued", "waiting", "pending", "requested"]

final class CIClient {
    private var tokens: [String: String] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func fetchAll() async -> [RepoCI] {
        var results: [RepoCI] = []
        for repo in Config.repos {
            results.append(await fetch(repo))
        }
        return results
    }

    private func fetch(_ repo: RepoWatch) async -> RepoCI {
        do {
            let runs = try await loadRuns(repo, retryOnAuth: true)
            return summarise(repo: repo, runs: runs)
        } catch {
            return RepoCI(label: repo.label, failures: [], running: 0, queued: 0,
                          error: error.localizedDescription, checkedAt: Date())
        }
    }

    private func loadRuns(_ repo: RepoWatch, retryOnAuth: Bool) async throws -> [[String: Any]] {
        let since = iso.string(from: Date().addingTimeInterval(-Config.ciLookbackHours * 3600))
        var comps = URLComponents(string: "https://api.github.com/repos/\(repo.fullName)/actions/runs")!
        comps.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "created", value: ">=\(since)"),
        ]
        let req = try authorizedRequest(comps.url!, user: repo.ghUser)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && retryOnAuth {
            tokens[repo.ghUser] = nil
            return try await loadRuns(repo, retryOnAuth: false)
        }
        guard code == 200 else { throw CIError.http(code) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["workflow_runs"] as? [[String: Any]] ?? []
    }

    private func summarise(repo: RepoWatch, runs: [[String: Any]]) -> RepoCI {
        let relevant = runs.filter { run in
            guard !(repo.actors.isEmpty && repo.branches.isEmpty) else { return true }
            let actor = (run["actor"] as? [String: Any])?["login"] as? String ?? ""
            let branch = run["head_branch"] as? String ?? ""
            return repo.actors.contains(actor) || repo.branches.contains(branch)
        }

        // Runs arrive newest first; only the latest run per workflow+branch decides its state.
        let latest = relevant.reduce(into: (seen: Set<String>(), runs: [[String: Any]]())) { acc, run in
            let key = "\(run["name"] as? String ?? "")|\(run["head_branch"] as? String ?? "")"
            guard !acc.seen.contains(key) else { return }
            acc.seen.insert(key)
            acc.runs.append(run)
        }.runs

        let failures = latest.compactMap { run -> FailedRun? in
            guard run["status"] as? String == "completed",
                  failedConclusions.contains(run["conclusion"] as? String ?? ""),
                  let id = (run["id"] as? NSNumber)?.intValue,
                  let url = URL(string: run["html_url"] as? String ?? "")
            else { return nil }
            return FailedRun(
                id: id,
                workflow: run["name"] as? String ?? "?",
                branch: run["head_branch"] as? String ?? "?",
                actor: (run["actor"] as? [String: Any])?["login"] as? String ?? "",
                finishedAt: iso.date(from: run["updated_at"] as? String ?? "") ?? Date(),
                url: url,
                scheduled: run["event"] as? String == "schedule",
                createdAt: iso.date(from: run["created_at"] as? String ?? "") ?? Date()
            )
        }

        let statuses = relevant.map { $0["status"] as? String ?? "" }
        return RepoCI(
            label: repo.label,
            failures: failures,
            running: statuses.filter { $0 == "in_progress" }.count,
            queued: statuses.filter { queuedStatuses.contains($0) }.count,
            error: nil,
            checkedAt: Date()
        )
    }

    func authorizedRequest(_ url: URL, user: String) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try token(for: user))", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        return req
    }

    private func token(for user: String) throws -> String {
        if let t = tokens[user] { return t }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Config.ghPath)
        proc.arguments = ["auth", "token", "--user", user]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let t = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !t.isEmpty else { throw CIError.noToken(user) }
        tokens[user] = t
        return t
    }
}

enum CIError: LocalizedError {
    case http(Int)
    case noToken(String)

    var errorDescription: String? {
        switch self {
        case .http(let c): return "GitHub HTTP \(c)"
        case .noToken(let u): return "no gh token for \(u)"
        }
    }
}
