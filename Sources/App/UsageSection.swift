import SwiftUI

struct UsageSection: View {
    @ObservedObject var store: Store

    var body: some View {
        PanelSection {
            SectionLabel(title: "Usage")
            VStack(spacing: 8) {
                ForEach(Config.profiles, id: \.self) { p in
                    UsageRow(store: store, profile: p, usage: store.usage.first { $0.profile == p })
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

private struct UsageRow: View {
    @ObservedObject var store: Store
    let profile: Profile
    let usage: AccountUsage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.title).font(Fonts.bodyMedium)
                Text(usage.map { "seen \(ago($0.observedAt, now: store.now)) ago" } ?? "no data yet")
                    .font(Fonts.small)
                    .foregroundColor(Palette.faint)
                if let c = usage?.costToday, c > 0 {
                    Text(String(format: "$%.2f active", c))
                        .font(Fonts.small)
                        .foregroundColor(Palette.faint)
                        .help("Running cost of the sessions active today, each since it started, at API list prices. An estimate from Claude Code, not a bill.")
                }
            }
            .frame(width: 84, alignment: .leading)
            ForEach(UsageWindow.allCases, id: \.self) { window in
                UsageWindowMeter(
                    name: window.rawValue,
                    window: usage?[window],
                    eta: usage.flatMap { store.limitETA($0, window) },
                    now: store.now
                )
            }
        }
    }
}

private struct UsageWindowMeter: View {
    let name: String
    let window: RateWindow?
    /// When the recent rate would hit the limit before the window resets.
    let eta: Date?
    let now: Date

    var body: some View {
        let live = window.flatMap { $0.resetsAt > now ? $0 : nil }
        let used = live?.usedPercent ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(name).font(Fonts.small).foregroundColor(Palette.dim)
                Spacer(minLength: 2)
                Text(live.map { "\(Int($0.usedPercent))%" } ?? "—").font(Fonts.num)
            }
            Bar(fraction: used / 100, color: Palette.load(used, warnAt: PanelThresholds.usageCaution, badAt: Config.usageWarnUsed))
            if let eta {
                Text("limit ~\(clockTime(eta))")
                    .font(Fonts.small.weight(.semibold))
                    .foregroundColor(Palette.warn)
                    .lineLimit(1)
                    .help("At the recent rate this window reaches 100% at \(clockTime(eta)), before it resets in \(live.map { until($0.resetsAt, now: now) } ?? "?")")
            } else {
                Text(live.map { "resets \(until($0.resetsAt, now: now))" } ?? "reset")
                    .font(Fonts.small)
                    .foregroundColor(Palette.faint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
