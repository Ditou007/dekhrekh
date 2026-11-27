import SwiftUI

struct ServerSection: View {
    @ObservedObject var store: Store
    let card: ServerCard

    var body: some View {
        PanelSection {
            Button { store.homelabExpanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    FoldLabel(title: card.title, expanded: store.homelabExpanded) {
                        if let h = store.homelab {
                            let (text, color) = verdict(h)
                            Pill(text: text, color: color)
                        }
                    }
                    if let h = store.homelab {
                        meters(h)
                    } else if let err = store.homelabError {
                        Text("Unreachable: \(err)").font(Fonts.small).foregroundColor(Palette.warn).lineLimit(1)
                    } else {
                        Text("Checking…").font(Fonts.small).foregroundColor(Palette.dim)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.homelabExpanded, let h = store.homelab {
                ServerDetail(status: h)
            }
        }
    }

    /// One-word read of the box: is it idle, fine, or struggling, and why.
    private func verdict(_ h: HomelabStatus) -> (String, Color) {
        let temp = h.tempC ?? 0
        if !h.guestsDown.isEmpty { return ("\(h.guestsDown.count) down", Palette.bad) }
        if temp >= card.tempBadC { return ("hot", Palette.bad) }
        if h.memPct >= Config.memoryWarnUsed { return ("memory tight", Palette.bad) }
        if h.loadPct >= PanelThresholds.loadMax { return ("overloaded", Palette.bad) }
        if h.loadPct >= PanelThresholds.loadCaution || h.memPct >= PanelThresholds.memoryCaution || temp >= card.tempWarnC {
            return ("busy", Palette.warn)
        }
        if h.loadPct < PanelThresholds.idleLoad && h.memPct < PanelThresholds.idleMemory { return ("underused", Palette.busy) }
        return ("healthy", Palette.ok)
    }

    private func meters(_ h: HomelabStatus) -> some View {
        VStack(spacing: 5) {
            MeterRow(
                name: "mem",
                fraction: h.memPct / 100,
                color: Palette.load(h.memPct, warnAt: PanelThresholds.memoryCaution, badAt: Config.memoryWarnUsed),
                value: String(format: "%.1f / %.0fG", h.memUsedGB, h.memTotalGB)
            )
            MeterRow(
                name: "cpu",
                fraction: h.loadPct / 100,
                color: Palette.load(h.loadPct, warnAt: PanelThresholds.loadCaution, badAt: PanelThresholds.loadMax),
                value: String(format: "load %.1f / %d", h.load1, h.cores)
            )
            if let t = h.tempC {
                MeterRow(
                    name: "temp",
                    fraction: t / 100,
                    color: Palette.load(t, warnAt: card.tempWarnC, badAt: card.tempBadC),
                    value: "\(Int(t))°C"
                )
            }
        }
        .padding(.horizontal, 6)
    }
}

private struct MeterRow: View {
    let name: String
    let fraction: Double
    let color: Color
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(Fonts.small).foregroundColor(Palette.dim).frame(width: 30, alignment: .leading)
            Bar(fraction: fraction, color: color)
            Text(value).font(Fonts.num).frame(width: 96, alignment: .trailing)
        }
    }
}

private struct ServerDetail: View {
    let status: HomelabStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let arc = status.arcGB, arc > 0 {
                    Text(String(format: "ZFS cache %.1fG (reclaimable)", arc))
                }
                Text(String(format: "disk %.0f%%", status.diskPct))
                Text("up \(Int(status.uptimeH / 24))d")
            }
            .font(Fonts.small)
            .foregroundColor(Palette.faint)

            if status.guests.isEmpty {
                Text("Per-guest breakdown needs the updated status script on the host.")
                    .font(Fonts.small)
                    .foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let top = status.guests.map(\.memGB).max() ?? 1
                ForEach(status.guests) { g in
                    HStack(spacing: 8) {
                        Circle().fill(g.running ? Palette.ok : Palette.bad).frame(width: 5, height: 5)
                        Text(g.name).font(Fonts.body).lineLimit(1)
                        Text(g.kind == "qemu" ? "vm" : g.kind).font(Fonts.label).foregroundColor(Palette.faint)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f%%", g.hostCpuPct))
                            .font(Fonts.numSmall)
                            .foregroundColor(g.hostCpuPct >= PanelThresholds.guestCPUCaution ? Palette.warn : Palette.faint)
                            .frame(width: 30, alignment: .trailing)
                        Bar(fraction: g.memGB / max(top, 0.01), color: Palette.busy.opacity(0.7), height: 3)
                            .frame(width: 40)
                        Text(String(format: "%.1f/%.0fG", g.memGB, g.maxMemGB))
                            .font(Fonts.num)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .help("\(g.kind) \(g.id)")
                }
            }
        }
        .padding(.horizontal, 6)
    }
}
