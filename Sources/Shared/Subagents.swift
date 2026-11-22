import Foundation

struct RunningSubagent: Codable {
    let agentId: String
    let description: String
    let lastActive: Date
}

/// Subagents a session started that have not finished. They run inside the session's own process,
/// so a restart kills them and resuming the session does not bring them back.
enum Subagents {
    /// A subagent whose parent died never gets its `finished` flag; past this much silence it is
    /// not counted as running.
    static let staleSeconds: TimeInterval = 30 * 60

    static func running(for s: Session, statusline: [String: [String: Any]]) -> [RunningSubagent] {
        guard let transcript = TranscriptReader.path(sessionId: s.id, statusline: statusline) else { return [] }
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let fm = FileManager.default
        let metas = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
        let now = Date()
        return metas.compactMap { meta -> RunningSubagent? in
            guard let data = try? Data(contentsOf: meta),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  o["finished"] as? Bool != true
            else { return nil }
            let id = meta.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")
            let log = dir.appendingPathComponent("\(id).jsonl")
            let modified = (try? fm.attributesOfItem(atPath: log.path)[.modificationDate] as? Date) ?? .distantPast
            guard now.timeIntervalSince(modified) < staleSeconds else { return nil }
            return RunningSubagent(agentId: id, description: o["description"] as? String ?? id, lastActive: modified)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }
}

/// What a restart would interrupt right now.
struct RestartCheck {
    let busy: [Session]
    let subagents: [(session: Session, agents: [RunningSubagent])]

    var safe: Bool { busy.isEmpty && subagents.isEmpty }

    var blockers: [String] {
        busy.map { "\($0.name) is \($0.status.rawValue)" }
            + subagents.map { s, a in "\(a.count) subagent\(a.count == 1 ? "" : "s") running in \(s.name): \(a.map(\.description).joined(separator: ", "))" }
    }

    static func now(sessions: [Session], statusline: [String: [String: Any]]) -> RestartCheck {
        RestartCheck(
            busy: sessions.filter { !$0.isBackground && ($0.status == .busy || $0.status == .shell) },
            subagents: sessions.compactMap { s in
                let a = Subagents.running(for: s, statusline: statusline)
                return a.isEmpty ? nil : (s, a)
            }
        )
    }
}
