import Foundation

enum PRState: Int, Comparable {
    /// Ordered by how urgently it wants the user.
    case failing, reviewRequested, readyToMerge, changesRequested, checksRunning, awaitingReview, draft

    static func < (a: PRState, b: PRState) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .failing: return "checks failing"
        case .reviewRequested: return "your review"
        case .readyToMerge: return "ready to merge"
        case .changesRequested: return "changes requested"
        case .checksRunning: return "checks running"
        case .awaitingReview: return "awaiting review"
        case .draft: return "draft"
        }
    }

    /// States that need the user to do something now.
    var needsYou: Bool { self == .failing || self == .reviewRequested || self == .readyToMerge || self == .changesRequested }
}

struct PullRequest: Identifiable {
    var id: String { "\(repo)#\(number)" }
    let repo: String
    let number: Int
    let title: String
    let author: String
    let state: PRState
    let updatedAt: Date
    let url: URL
}

private let prQuery = """
query($q: String!) {
  search(query: $q, type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number title url isDraft updatedAt reviewDecision
        author { login }
        reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } } } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}
"""

extension CIClient {
    func fetchPRs() async -> (prs: [PullRequest], errors: [String]) {
        var prs: [PullRequest] = []
        var errors: [String] = []
        for repo in Config.repos {
            do {
                prs += try await loadPRs(repo)
            } catch {
                errors.append("\(repo.label): \(error.localizedDescription)")
            }
        }
        return (prs.sorted { $0.state != $1.state ? $0.state < $1.state : $0.updatedAt > $1.updatedAt }, errors)
    }

    private func loadPRs(_ repo: RepoWatch) async throws -> [PullRequest] {
        let body: [String: Any] = [
            "query": prQuery,
            "variables": ["q": "repo:\(repo.fullName) is:pr is:open involves:\(repo.ghUser)"],
        ]
        var req = try authorizedRequest(URL(string: "https://api.github.com/graphql")!, user: repo.ghUser)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let nodes = ((obj?["data"] as? [String: Any])?["search"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()

        return nodes.compactMap { n -> PullRequest? in
            guard let number = (n["number"] as? NSNumber)?.intValue,
                  let url = URL(string: n["url"] as? String ?? "")
            else { return nil }
            let author = (n["author"] as? [String: Any])?["login"] as? String ?? ""
            let requested = ((n["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
                .compactMap { ($0["requestedReviewer"] as? [String: Any])?["login"] as? String }
            let checks = ((((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]
                as? [String: Any])?["statusCheckRollup"] as? [String: Any])?["state"] as? String
            let mine = author == repo.ghUser

            let state: PRState? = {
                if !mine { return requested.contains(repo.ghUser) ? .reviewRequested : nil }
                if n["isDraft"] as? Bool == true { return .draft }
                if checks == "FAILURE" || checks == "ERROR" { return .failing }
                if checks == "PENDING" || checks == "EXPECTED" { return .checksRunning }
                switch n["reviewDecision"] as? String {
                case "APPROVED": return .readyToMerge
                case "CHANGES_REQUESTED": return .changesRequested
                default: return .awaitingReview
                }
            }()
            guard let state else { return nil }
            return PullRequest(
                repo: repo.label, number: number, title: n["title"] as? String ?? "", author: author,
                state: state, updatedAt: iso.date(from: n["updatedAt"] as? String ?? "") ?? Date(), url: url
            )
        }
    }
}
