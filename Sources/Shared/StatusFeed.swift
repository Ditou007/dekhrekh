import Foundation

/// One session's latest status-line payload, as `dekhrekh feed statusline` saved it: the JSON Claude
/// Code passes to its status-line command, plus `widget_profile` and `widget_ts` added by the feed.
/// Only the fields read here are decoded; everything is optional because older Claude Code versions
/// leave some out.
struct StatusFeed: Decodable {
    struct ContextWindow: Decodable { let remainingPercentage: Double? }
    struct Window: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?
    }
    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
    }
    struct Cost: Decodable { let totalCostUsd: Double? }
    struct Model: Decodable { let id: String? }
    struct Effort: Decodable { let level: String? }

    let sessionId: String
    let sessionName: String?
    let transcriptPath: String?
    let contextWindow: ContextWindow?
    let rateLimits: RateLimits?
    let cost: Cost?
    let model: Model?
    let effort: Effort?
    let widgetProfile: String?
    let widgetTs: Double?

    static func decode(_ data: Data) -> StatusFeed? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(StatusFeed.self, from: data)
    }
}

/// Every session's status feed, by session id.
typealias StatusFeeds = [String: StatusFeed]

extension StatusFeed.Window {
    var rateWindow: RateWindow? {
        guard let usedPercentage, let resetsAt else { return nil }
        return RateWindow(usedPercent: usedPercentage, resetsAt: Date(timeIntervalSince1970: resetsAt))
    }
}
