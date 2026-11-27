import Foundation

/// Usage samples over time, so the burn rate (and when a window will hit 100%) can be projected.
/// One JSON line per change: {"p":"work","w":"5h","r":<resets_at>,"u":<used%>,"t":<epoch>}.
enum UsageHistory {
    static let file = Config.stateDir.appendingPathComponent("usage-history.jsonl")
    static let keepSeconds: TimeInterval = 26 * 3600

    /// How much recent history the rate is measured over, and the least that gives a usable rate.
    /// The 7-day window needs a long span: one busy hour says nothing about a week with nights in it.
    static let minUsedForForecast = 50.0
    static let shortSpan: (lookback: TimeInterval, minimum: TimeInterval) = (3600, 600)
    static let weekSpan: (lookback: TimeInterval, minimum: TimeInterval) = (86400, 21600)

    static func rateSpan(_ window: UsageWindow) -> (lookback: TimeInterval, minimum: TimeInterval) {
        window == .sevenDay ? weekSpan : shortSpan
    }

    struct Sample {
        let profile: String
        let window: String
        let resetsAt: TimeInterval
        let used: Double
        let at: TimeInterval
    }

    static func read() -> [Sample] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let p = o["p"] as? String, let w = o["w"] as? String,
                  let r = (o["r"] as? NSNumber)?.doubleValue, let u = (o["u"] as? NSNumber)?.doubleValue,
                  let t = (o["t"] as? NSNumber)?.doubleValue
            else { return nil }
            return Sample(profile: p, window: w, resetsAt: r, used: u, at: t)
        }
    }

    /// Appends a sample per window whose value changed since the last one, and drops old lines.
    static func record(_ usage: [AccountUsage], existing: [Sample]) -> [Sample] {
        let now = Date().timeIntervalSince1970
        let fresh = usage.flatMap { u -> [Sample] in
            UsageWindow.allCases.compactMap { window in
                guard let w = u[window] else { return nil }
                let name = window.rawValue
                let last = existing.last { $0.profile == u.profile.rawValue && $0.window == name }
                let unchanged = last.map { $0.used == w.usedPercent && $0.resetsAt == w.resetsAt.timeIntervalSince1970 } ?? false
                return unchanged ? nil : Sample(profile: u.profile.rawValue, window: name,
                                                resetsAt: w.resetsAt.timeIntervalSince1970,
                                                used: w.usedPercent, at: u.observedAt.timeIntervalSince1970)
            }
        }
        let kept = existing.filter { now - $0.at < keepSeconds }
        guard !fresh.isEmpty || kept.count != existing.count else { return existing }
        let all = kept + fresh
        let lines = all.compactMap { s -> String? in
            let obj: [String: Any] = ["p": s.profile, "w": s.window, "r": Int(s.resetsAt), "u": s.used, "t": Int(s.at)]
            return (try? JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return all
    }

    /// When the window will reach 100% at the recent rate, if that comes before it resets.
    static func limitETA(profile: Profile, window: UsageWindow, current: RateWindow, samples: [Sample], now: Date) -> Date? {
        let r = current.resetsAt.timeIntervalSince1970
        let t = now.timeIntervalSince1970
        // Early in a window a few minutes of work extrapolates wildly; forecast only past halfway.
        guard current.usedPercent >= minUsedForForecast else { return nil }
        let limits = rateSpan(window)
        let recent = samples.filter {
            $0.profile == profile.rawValue && $0.window == window.rawValue && $0.resetsAt == r && t - $0.at <= limits.lookback
        }
        guard let first = recent.min(by: { $0.at < $1.at }) else { return nil }
        let span = t - first.at
        let gained = current.usedPercent - first.used
        guard span >= limits.minimum, gained > 0 else { return nil }
        let eta = t + (100 - current.usedPercent) / (gained / span)
        return eta < r ? Date(timeIntervalSince1970: eta) : nil
    }
}

/// "14:20" today, "Thu 07:52" on another day.
func clockTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: d)
}
