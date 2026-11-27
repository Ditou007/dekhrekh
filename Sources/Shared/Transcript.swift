import Foundation

struct Prompt {
    let at: Date?
    let text: String
}

struct ToolAction {
    let tool: String
    let detail: String
}

struct SessionContext {
    let title: String?
    let lastPrompt: String?
    let prompts: [Prompt]
    let replies: [String]
    let actions: [ToolAction]
    /// The last tool call with no result yet: what a waiting session is blocked on.
    let pending: ToolAction?
    let transcriptPath: String?
}

enum TranscriptReader {
    /// Only the tail is read: transcripts reach tens of MB and the recent part is what matters.
    static let tailBytes = 3_000_000

    static func path(sessionId: String, statusline: StatusFeeds) -> URL? {
        if let p = statusline[sessionId]?.transcriptPath, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let roots = Config.profiles.map(\.projectsDir)
        let fm = FileManager.default
        for root in roots {
            let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            if let hit = dirs.map({ $0.appendingPathComponent("\(sessionId).jsonl") })
                .first(where: { fm.fileExists(atPath: $0.path) }) {
                return hit
            }
        }
        return nil
    }

    static func context(for s: Session, statusline: StatusFeeds,
                        prompts promptLimit: Int = 5, replies replyLimit: Int = 2,
                        actions actionLimit: Int = 10) -> SessionContext {
        let url = path(sessionId: s.id, statusline: statusline)
        let lines = url.map(tailLines) ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var title: String?
        var lastPrompt: String?
        var prompts: [Prompt] = []
        var replies: [String] = []
        var actions: [ToolAction] = []
        var openCalls: [(id: String, action: ToolAction)] = []
        var resolved = Set<String>()

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "ai-title":
                title = obj["aiTitle"] as? String ?? title
            case "last-prompt":
                lastPrompt = obj["lastPrompt"] as? String ?? lastPrompt
            case "user":
                if let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                    blocks.compactMap { $0["tool_use_id"] as? String }.forEach { resolved.insert($0) }
                }
                // isMeta marks harness-injected content such as a loaded skill's body.
                guard obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                      let text = promptText((obj["message"] as? [String: Any])?["content"]),
                      isHumanPrompt(text)
                else { continue }
                prompts.append(Prompt(at: iso.date(from: obj["timestamp"] as? String ?? ""), text: text))
            case "assistant":
                guard obj["isSidechain"] as? Bool != true,
                      let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]]
                else { continue }
                for b in blocks {
                    if b["type"] as? String == "text", let t = b["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        replies.append(t)
                    } else if b["type"] as? String == "tool_use" {
                        let a = action(b)
                        actions.append(a)
                        if let id = b["id"] as? String { openCalls.append((id, a)) }
                    }
                }
            default:
                continue
            }
        }

        return SessionContext(
            title: title,
            lastPrompt: lastPrompt ?? prompts.last?.text,
            prompts: Array(prompts.suffix(promptLimit)),
            replies: Array(replies.suffix(replyLimit)),
            actions: Array(actions.suffix(actionLimit)),
            pending: openCalls.last { !resolved.contains($0.id) }?.action,
            transcriptPath: url?.path
        )
    }

    /// Typed prompts only: harness wrappers (task notifications, slash-command echoes,
    /// system reminders) and messages relayed from other sessions arrive as user messages too.
    private static let relayedPrefixes = ["<", "Another Claude session sent a message"]

    private static func isHumanPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A message that is only a paste starts with the paste tag, but the user did send it.
        if t.hasPrefix("<pasted_content") { return true }
        return !t.isEmpty && !relayedPrefixes.contains { t.hasPrefix($0) }
    }

    /// A typed prompt is a plain string; a paste or an attached image makes it a list of blocks.
    /// Lists holding a tool_result are tool output, not something the user typed.
    private static func promptText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]],
              !blocks.contains(where: { $0["type"] as? String == "tool_result" })
        else { return nil }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func action(_ block: [String: Any]) -> ToolAction {
        let name = block["name"] as? String ?? "?"
        let input = block["input"] as? [String: Any] ?? [:]
        let keys = ["description", "file_path", "pattern", "query", "url", "prompt", "command"]
        let question = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
        let detail = question ?? keys.lazy.compactMap { input[$0] as? String }.first ?? ""
        return ToolAction(tool: name, detail: oneLine(detail, max: 100))
    }

    private static func tailLines(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map(String.init)
    }

}

func oneLine(_ s: String, max: Int) -> String {
    let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}
