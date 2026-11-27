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

let failedConclusions: Set<String> = ["failure", "timed_out", "startup_failure"]
private let queuedStatuses: Set<String> = ["queued", "waiting", "pending", "requested"]

/// Shared by the CI, PR and stats fetches, which run concurrently.
final class CIClient: @unchecked Sendable {
    /// `gh auth token` per login; guarded by `lock`.
    private var tokens: [String: String] = [:]
    private let lock = NSLock()
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
            return summarise(repo: repo, runs: runs, live: await liveBranches(repo))
        } catch {
            return RepoCI(label: repo.label, failures: [], running: 0, queued: 0,
                          error: error.localizedDescription, checkedAt: Date())
        }
    }

    private func loadRuns(_ repo: RepoWatch, retryOnAuth: Bool) async throws -> [[String: Any]] {
        let since = iso.string(from: Date().addingTimeInterval(-Config.ciLookbackHours * 3600))
        let url = Self.apiURL(repo, "/actions/runs", query: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "created", value: ">=\(since)"),
        ])
        let req = try authorizedRequest(url, user: repo.ghUser)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && retryOnAuth {
            forgetToken(for: repo.ghUser)
            return try await loadRuns(repo, retryOnAuth: false)
        }
        guard code == 200 else { throw CIError.http(code) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["workflow_runs"] as? [[String: Any]] ?? []
    }

    /// Branches whose failures matter: the default branch, every open PR's head, and branches named in
    /// the config. A red run on a closed PR's branch or an unpushed-for-review branch is not a failure
    /// anyone needs to act on. Nil when GitHub cannot be read, so nothing is hidden by mistake.
    private func liveBranches(_ repo: RepoWatch) async -> Set<String>? {
        func get(_ path: String, _ query: [URLQueryItem] = []) async -> Any? {
            guard let req = try? authorizedRequest(Self.apiURL(repo, path, query: query), user: repo.ghUser),
                  let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        guard let info = await get("") as? [String: Any], let main = info["default_branch"] as? String,
              let pulls = await get("/pulls", [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "per_page", value: "100")]) as? [[String: Any]]
        else { return nil }
        let heads = pulls.compactMap { ($0["head"] as? [String: Any])?["ref"] as? String }
        return Set(heads).union(repo.branches).union([main])
    }

    private func summarise(repo: RepoWatch, runs: [[String: Any]], live: Set<String>?) -> RepoCI {
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
            guard live.map({ $0.contains(run["head_branch"] as? String ?? "") }) ?? true,
                  run["status"] as? String == "completed",
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

    /// GET a GitHub REST URL and decode its JSON object; any status but 200 throws.
    func getJSON(_ url: URL, user: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: try authorizedRequest(url, user: user))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func authorizedRequest(_ url: URL, user: String) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try token(for: user))", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        return req
    }

    private func token(for user: String) throws -> String {
        lock.lock()
        let hit = tokens[user]
        lock.unlock()
        if let hit { return hit }
        guard !user.isEmpty else { throw CIError.noLogin }
        guard let r = Shell.run(Config.ghPath, ["auth", "token", "--user", user]), r.ok, !r.text.isEmpty
        else { throw CIError.noToken(user) }
        lock.lock()
        tokens[user] = r.text
        lock.unlock()
        return r.text
    }

    func forgetToken(for user: String) {
        lock.lock()
        tokens[user] = nil
        lock.unlock()
    }

    /// A GitHub REST URL for `repo`; the repo name is validated when the config is read.
    static func apiURL(_ repo: RepoWatch, _ path: String = "", query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.github.com"
        comps.path = "/repos/\(repo.fullName)" + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { preconditionFailure("invalid repo name \(repo.fullName)") }
        return url
    }
}

enum CIError: LocalizedError {
    case http(Int)
    case noToken(String)
    /// No `ghUser` in the config and `gh` could not say who is signed in.
    case noLogin

    var errorDescription: String? {
        switch self {
        case .http(let c): return "GitHub HTTP \(c)"
        case .noToken(let u): return "no gh token for \(u)"
        case .noLogin: return "gh not found or not signed in (set ghPath or ghUser in the config)"
        }
    }
}
