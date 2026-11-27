import SwiftUI

private let panelWidth: CGFloat = 320

struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store)
            if !store.compact {
                PanelDivider()
                ScrollView(.vertical) {
                    sections
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BodyHeightKey.self, value: g.size.height)
                        })
                }
                .scrollIndicators(overflows ? .visible : .never)
                .frame(height: min(store.bodyHeight, store.maxBodyHeight))
                .overlay(alignment: .bottom) {
                    if overflows {
                        LinearGradient(colors: [Palette.bg.opacity(0), Palette.bg], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(BodyHeightKey.self) { h in
                    if abs(store.bodyHeight - h) > 0.5 { store.bodyHeight = h }
                }
            }
        }
        .foregroundColor(Palette.text)
        .frame(width: panelWidth)
        .background(Palette.bg.opacity(Config.panelOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(store.attention == .alert ? Palette.bad.opacity(0.55) : Palette.border, lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
    }

    private var overflows: Bool { store.bodyHeight > store.maxBodyHeight }

    private var sections: some View {
        VStack(spacing: 0) {
            if let err = Config.user.loadError {
                PanelSection { Text(err).font(Fonts.small).foregroundColor(Palette.warn) }
                PanelDivider()
            }
            if !Config.repos.isEmpty {
                CISection(store: store)
                PanelDivider()
                PRSection(store: store)
                PanelDivider()
            }
            SessionsSection(store: store)
            PanelDivider()
            UsageSection(store: store)
            PanelDivider()
            MemorySection(store: store)
            if let card = Config.server {
                PanelDivider()
                ServerSection(store: store, card: card)
            }
        }
    }
}

private struct PanelDivider: View {
    var body: some View {
        Rectangle().fill(Palette.border).frame(height: 1)
    }
}

private struct PanelHeader: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Config.iconSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.attention(store.attention))
            // The first layout that fits on one line: full title and pills, then pills only, then
            // short pills. Nothing wraps, so the bar keeps its height however many alerts are up.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(Config.appName).font(Fonts.title).lineLimit(1).fixedSize()
                    Spacer(minLength: 6)
                    HeaderPills(store: store, short: false)
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    HeaderPills(store: store, short: false)
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    HeaderPills(store: store, short: true)
                }
            }
            Button { store.compact.toggle() } label: {
                Image(systemName: store.compact ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Palette.faint)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.compact.toggle() }
    }
}

private struct HeaderPills: View {
    @ObservedObject var store: Store
    let short: Bool

    var body: some View {
        if allClear {
            Text("All clear").font(Fonts.small).foregroundColor(Palette.dim).lineLimit(1).fixedSize()
        }
        if store.failureCount > 0 {
            Pill(text: "\(store.failureCount) CI", color: Palette.bad)
        }
        if store.askingCount > 0 {
            Pill(text: "\(store.askingCount) \(short ? "ask" : "asking")", color: Palette.warn)
                .help("\(store.askingCount) session(s) ended their turn with a question for you")
        }
        if store.waitingCount > 0 {
            Pill(text: "\(store.waitingCount) \(short ? "wait" : "waiting")", color: Palette.warn)
                .help("\(store.waitingCount) session(s) waiting on a permission prompt or input")
        }
        if store.prsNeedingYou > 0 {
            Pill(text: "\(store.prsNeedingYou) PR", color: Palette.busy)
        }
        if store.lowContextCount > 0 {
            Pill(text: "\(store.lowContextCount) \(short ? "ctx" : "low ctx")", color: Palette.bad)
                .help("\(store.lowContextCount) session(s) below \(Int(Config.ctxCriticalRemaining))% context")
        }
    }

    private var allClear: Bool {
        let pills = store.failureCount + store.waitingCount + store.askingCount + store.lowContextCount + store.prsNeedingYou
        return pills == 0 && store.attention == .calm
    }
}
