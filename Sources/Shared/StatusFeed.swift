import Foundation

/// One session's latest status-line payload, as `dekhrekh feed statusline` saved it: the JSON Claude
/// Code passes to its status-line command, plus `widget_profile` and `widget_ts` added by the feed.
/// Only the fields read here are decoded. Only `session_id` is required: any other field that is
/// missing or has an unexpected shape is read as nil, so one changed field cannot hide the session.
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

    private enum CodingKeys: String, CodingKey {
        case sessionId, sessionName, transcriptPath, contextWindow, rateLimits, cost, model, effort
        case widgetProfile, widgetTs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        sessionId = try c.decode(String.self, forKey: .sessionId)
        sessionName = field(.sessionName)
        transcriptPath = field(.transcriptPath)
        contextWindow = field(.contextWindow)
        rateLimits = field(.rateLimits)
        cost = field(.cost)
        model = field(.model)
        effort = field(.effort)
        widgetProfile = field(.widgetProfile)
        widgetTs = field(.widgetTs)
    }

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
