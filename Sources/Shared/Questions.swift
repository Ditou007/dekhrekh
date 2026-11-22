import Foundation

/// A session that finished its turn by asking something in plain prose ("Should I start?") is
/// waiting on the user, but Claude Code reports it as plain idle. Only the multiple-choice and
/// permission prompts show as "waiting", so this reads the last reply instead.
enum Questions {
    /// Only the end of the reply counts: a question in the middle of a long report is rhetorical
    /// or already answered by what follows.
    static let tailCharacters = 500

    private static var cache: [String: (modified: Date, question: String?)] = [:]

    /// The question an idle session ended its turn with, or nil.
    static func pending(for s: Session, statusline: [String: [String: Any]]) -> String? {
        guard s.status == .idle, !s.isBackground,
              let path = TranscriptReader.path(sessionId: s.id, statusline: statusline)
        else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
            ?? .distantPast
        if let hit = cache[s.id], hit.modified == modified { return hit.question }
        let ctx = TranscriptReader.context(for: s, statusline: statusline, prompts: 0, replies: 1, actions: 0)
        let q = ctx.replies.last.flatMap(question(in:))
        cache[s.id] = (modified, q)
        return q
    }

    /// The last sentence ending in "?" near the end of a reply, cleaned of markdown.
    static func question(in reply: String) -> String? {
        let tail = String(reply.suffix(tailCharacters))
        guard let mark = tail.lastIndex(of: "?") else { return nil }
        // Whatever follows the question must be short (a sign-off, a code block fence), or the
        // reply moved on after asking.
        guard tail[tail.index(after: mark)...].trimmingCharacters(in: .whitespacesAndNewlines).count < 120 else { return nil }
        let upto = tail[...mark]
        let start = upto.lastIndex { ".!\n".contains($0) }.map { upto.index(after: $0) } ?? upto.startIndex
        let sentence = upto[start...]
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count >= 8 ? sentence : nil
    }
}
