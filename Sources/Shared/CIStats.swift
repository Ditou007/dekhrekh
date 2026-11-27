import Foundation

struct JobStat {
    let name: String
    let count: Int
    let waitMedian: Double
    let waitMax: Double
    let runMedian: Double
    let runMax: Double
}

struct RepoStats {
    let label: String
    let runs: Int
    let wallMedian: Double?
    let wallMax: Double?
    let jobs: [JobStat]
    let error: String?
}

/// Queue wait (job created -> started) and run time (started -> completed), in minutes, over the
/// last completed runs. Skipped and cancelled jobs are left out; they never held a runner for long.
extension CIClient {
    func stats(runs limit: Int) async -> [RepoStats] {
        var out: [RepoStats] = []
        for repo in Config.repos {
            do {
                out.append(try await stats(repo, limit: limit))
            } catch {
                out.append(RepoStats(label: repo.label, runs: 0, wallMedian: nil, wallMax: nil, jobs: [],
                                     error: error.localizedDescription))
            }
        }
        return out
    }

    private func stats(_ repo: RepoWatch, limit: Int) async throws -> RepoStats {
        let iso = ISO8601DateFormatter()
        let list = try await getJSON(Self.apiURL(repo, "/actions/runs", query: [
            URLQueryItem(name: "status", value: "completed"), URLQueryItem(name: "per_page", value: "\(limit)"),
        ]), user: repo.ghUser)
        let runs = (list["workflow_runs"] as? [[String: Any]] ?? []).filter { run in
            guard run["conclusion"] as? String != "cancelled" else { return false }
            guard !(repo.actors.isEmpty && repo.branches.isEmpty) else { return true }
            let actor = (run["actor"] as? [String: Any])?["login"] as? String ?? ""
            return repo.actors.contains(actor) || repo.branches.contains(run["head_branch"] as? String ?? "")
        }

        var waits: [String: [Double]] = [:]
        var durations: [String: [Double]] = [:]
        var walls: [Double] = []
        for run in runs {
            guard let id = (run["id"] as? NSNumber)?.intValue else { continue }
            let jobs = try await getJSON(Self.apiURL(repo, "/actions/runs/\(id)/jobs", query: [URLQueryItem(name: "per_page", value: "100")]),
                                         user: repo.ghUser)["jobs"]
                as? [[String: Any]] ?? []
            var firstCreated: Date?
            var lastDone: Date?
            for j in jobs {
                let concl = j["conclusion"] as? String ?? ""
                guard concl != "skipped", concl != "cancelled",
                      let c = iso.date(from: j["created_at"] as? String ?? ""),
                      let s = iso.date(from: j["started_at"] as? String ?? ""),
                      let e = iso.date(from: j["completed_at"] as? String ?? "")
                else { continue }
                let name = j["name"] as? String ?? "?"
                waits[name, default: []].append(s.timeIntervalSince(c) / 60)
                durations[name, default: []].append(e.timeIntervalSince(s) / 60)
                firstCreated = min(firstCreated ?? c, c)
                lastDone = max(lastDone ?? e, e)
            }
            if let a = firstCreated, let b = lastDone { walls.append(b.timeIntervalSince(a) / 60) }
        }

        let jobs = waits.keys.sorted().map { name in
            let w = waits[name, default: []].sorted()
            let d = durations[name, default: []].sorted()
            return JobStat(name: name, count: w.count, waitMedian: median(w), waitMax: w.last ?? 0,
                           runMedian: median(d), runMax: d.last ?? 0)
        }
        let sortedWalls = walls.sorted()
        return RepoStats(label: repo.label, runs: runs.count,
                         wallMedian: sortedWalls.isEmpty ? nil : median(sortedWalls),
                         wallMax: sortedWalls.last, jobs: jobs, error: nil)
    }
}

private func median(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let m = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2
}
