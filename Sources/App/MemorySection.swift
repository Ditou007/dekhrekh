import SwiftUI

struct MemorySection: View {
    @ObservedObject var store: Store

    var body: some View {
        PanelSection {
            Button { store.memoryExpanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    FoldLabel(title: "Memory", expanded: store.memoryExpanded) { badges }
                    HStack(spacing: 10) {
                        Text("up \(formatDuration(store.macState.uptime))")
                        Text("pressure \(store.macState.pressure.label)")
                            .foregroundColor(store.macState.pressure == .normal ? Palette.faint : Palette.warn)
                    }
                    .font(Fonts.small)
                    .foregroundColor(Palette.faint)
                    .padding(.horizontal, 6)
                    if let m = store.memory, m.totalBytes > 0 {
                        let frac = Double(m.usedBytes) / Double(m.totalBytes)
                        HStack(spacing: 8) {
                            Bar(fraction: frac, color: Palette.load(frac * 100, warnAt: PanelThresholds.memoryCaution, badAt: Config.memoryWarnUsed))
                            Text("\(formatBytes(m.usedBytes)) / \(formatBytes(m.totalBytes))")
                                .font(Fonts.num)
                                .fixedSize()
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.memoryExpanded {
                TopAppsList(apps: store.topApps)
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        let reasons = store.macState.restartReasons
        if !reasons.isEmpty {
            Pill(text: "restart?", color: Palette.warn)
                .help(restartHelp(reasons))
        }
        if let d = store.dockerVMBytes {
            Pill(text: "Docker \(formatBytes(d))", color: Palette.warn)
                .help("The Docker VM is running and holding this much memory")
        }
        if let m = store.memory, m.swapUsedBytes > 0 {
            Text("swap \(formatBytes(m.swapUsedBytes))")
                .font(Fonts.numSmall)
                .foregroundColor(store.swapHot ? Palette.warn : Palette.faint)
        }
    }

    private func restartHelp(_ reasons: [String]) -> String {
        let why = "A restart would help: \(reasons.joined(separator: ", ")). Open Claude sessions are saved every minute and \(Config.appName) offers to reopen them afterwards."
        let check = store.restartCheck
        guard check.safe else {
            return why + "\n\nNot yet, a restart would interrupt:\n- " + check.blockers.joined(separator: "\n- ")
        }
        return why + "\n\nNothing is running right now: safe to restart."
    }
}

private struct TopAppsList: View {
    let apps: [AppMemory]

    var body: some View {
        let top = apps.first?.bytes ?? 1
        VStack(spacing: 4) {
            ForEach(apps) { a in
                HStack(spacing: 8) {
                    Text(a.name).font(Fonts.body).lineLimit(1).truncationMode(.tail)
                    if a.processCount > 1 {
                        Text("\(a.processCount)").font(Fonts.numSmall).foregroundColor(Palette.faint)
                    }
                    Spacer(minLength: 4)
                    Bar(fraction: Double(a.bytes) / Double(top), color: Palette.busy.opacity(0.7), height: 3)
                        .frame(width: 50)
                    Text(formatBytes(a.bytes)).font(Fonts.num).frame(width: 44, alignment: .trailing)
                }
            }
            if apps.isEmpty {
                Text("Reading…").font(Fonts.small).foregroundColor(Palette.dim)
            }
        }
        .padding(.horizontal, 6)
    }
}
