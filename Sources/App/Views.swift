import AppKit
import SwiftUI

/// SwiftUI's `State` property wrapper under a name that no macro shares. From the macOS 27 SDK on,
/// `@State` resolves to a macro whose plugin ships only with Xcode, so it fails to compile with
/// the Command Line Tools alone. The alias reaches the same property wrapper and builds with either.
typealias ViewState = SwiftUI.State

enum Palette {
    static let bg = Color(red: 0.08, green: 0.085, blue: 0.095)
    static let border = Color.white.opacity(0.10)
    static let track = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.06)
    static let text = Color(white: 0.93)
    static let dim = Color(white: 0.55)
    static let faint = Color(white: 0.38)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.20)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let busy = Color(red: 0.35, green: 0.80, blue: 0.95)

    static func attention(_ a: Attention) -> Color {
        switch a {
        case .calm: return ok
        case .warn: return warn
        case .alert: return bad
        }
    }

    /// Colour for a "used" percentage: calm until the warn line, red near the limit.
    static func load(_ used: Double, warnAt: Double, badAt: Double) -> Color {
        if used >= badAt { return bad }
        if used >= warnAt { return warn }
        return ok
    }
}

enum Type {
    static let title = Font.system(size: 12.5, weight: .semibold)
    static let body = Font.system(size: 12)
    static let bodyMedium = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 10.5)
    static let label = Font.system(size: 9.5, weight: .semibold)
    static let num = Font.system(size: 11, design: .monospaced)
    static let numSmall = Font.system(size: 10, design: .monospaced)
}

private let panelWidth: CGFloat = 320

// MARK: - Building blocks

struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color)
                    .frame(width: max(height, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var filled = true

    var body: some View {
        Text(text)
            .font(Type.small.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(filled ? color : Palette.dim)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(filled ? color.opacity(0.16) : Color.clear))
            .overlay(Capsule().stroke(filled ? Color.clear : Palette.border, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased()).font(Type.label).tracking(0.9).foregroundColor(Palette.faint)
            Spacer()
            if let trailing {
                Text(trailing).font(Type.numSmall).foregroundColor(Palette.faint)
            }
        }
    }
}

struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Palette.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Section<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: Store
    @ViewState private var showAllActivePRs = false
    @ViewState private var openPRGroups: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.compact {
                divider
                ScrollView(.vertical) {
                    sections
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BodyHeightKey.self, value: g.size.height)
                        })
                }
                .scrollIndicators(store.bodyHeight > store.maxBodyHeight ? .visible : .never)
                .frame(height: min(store.bodyHeight, store.maxBodyHeight))
                .overlay(alignment: .bottom) {
                    if store.bodyHeight > store.maxBodyHeight {
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

    private var sections: some View {
        VStack(spacing: 0) {
            if let err = Config.user.loadError {
                Section { Text(err).font(Type.small).foregroundColor(Palette.warn) }
                divider
            }
            if !Config.repos.isEmpty {
                Section { ciSection }
                divider
                Section { prSection }
                divider
            }
            Section { sessionSection }
            divider
            Section { usageSection }
            divider
            Section { memorySection }
            if Config.server != nil {
                divider
                Section { homelabSection }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: Config.iconSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.attention(store.attention))
            // The first layout that fits on one line: full title and pills, then pills only, then
            // short pills. Nothing wraps, so the bar keeps its height however many alerts are up.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(Config.appName).font(Type.title).lineLimit(1).fixedSize()
                    Spacer(minLength: 6)
                    headerPills(short: false)
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    headerPills(short: false)
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    headerPills(short: true)
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

    @ViewBuilder
    private func headerPills(short: Bool) -> some View {
        let any = store.failureCount + store.waitingCount + store.askingCount + store.lowContextCount + store.prsNeedingYou > 0
        if !any && store.attention == .calm {
            Text("All clear").font(Type.small).foregroundColor(Palette.dim).lineLimit(1).fixedSize()
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

    // MARK: CI

    @ViewBuilder
    private var ciSection: some View {
        SectionLabel(title: "CI", trailing: store.ci.first.map { "checked \(ago($0.checkedAt, now: store.now)) ago" })
        if store.ci.isEmpty {
            Text("Checking…").font(Type.small).foregroundColor(Palette.dim)
        }
        ForEach(store.ci) { repo in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    repoIcon(repo)
                    Text(repo.label).font(Type.bodyMedium)
                    Spacer()
                    if repo.running > 0 {
                        Text("\(repo.running) running").font(Type.small).foregroundColor(Palette.busy)
                    }
                    if repo.queued > 0 {
                        Text("\(repo.queued) queued").font(Type.small).foregroundColor(Palette.dim)
                    }
                }
                .padding(.horizontal, 6)
                if let err = repo.error {
                    Text(err).font(Type.small).foregroundColor(Palette.warn).padding(.leading, 28)
                }
                ForEach(repo.failures) { run in
                    HoverRow(action: { NSWorkspace.shared.open(run.url) }) {
                        HStack(spacing: 6) {
                            Text(run.branch)
                                .font(Type.num)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(run.scheduled ? Palette.warn : Palette.text)
                            Text(run.scheduled ? "nightly" : run.workflow)
                                .font(Type.small).foregroundColor(Palette.faint).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(run.scheduled
                                 ? "next \(clockTime(run.nextScheduledRun))"
                                 : ago(run.finishedAt, now: store.now))
                                .font(Type.numSmall).foregroundColor(Palette.dim)
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                                .foregroundColor(Palette.faint)
                        }
                        .padding(.leading, 22)
                    }
                    .help(run.scheduled
                          ? "\(run.workflow) failed \(ago(run.finishedAt, now: store.now)) ago. It stays failed until the next scheduled run (~\(clockTime(run.nextScheduledRun))) even if a fix has merged since. Open on GitHub"
                          : "\(run.workflow) by \(run.actor). Open on GitHub")
                }
            }
        }
    }

    private func repoIcon(_ repo: RepoCI) -> some View {
        let (name, color): (String, Color) = {
            if repo.error != nil { return ("exclamationmark.circle.fill", Palette.warn) }
            if repo.failures.contains(where: { !$0.scheduled }) { return ("xmark.circle.fill", Palette.bad) }
            if !repo.failures.isEmpty { return ("moon.circle.fill", Palette.warn) }
            if repo.running + repo.queued > 0 { return ("circle.dotted.circle", Palette.busy) }
            return ("checkmark.circle.fill", Palette.ok)
        }()
        return Image(systemName: name).font(.system(size: 13)).foregroundColor(color).frame(width: 14)
    }

    // MARK: Pull requests

    @ViewBuilder
    private var prSection: some View {
        let active = store.prs.filter { $0.state.needsYou || $0.state == .checksRunning }
        let parked = store.prs.filter { !($0.state.needsYou || $0.state == .checksRunning) }
        Button { store.prsExpanded.toggle() } label: {
            HStack(spacing: 4) {
                Text("PULL REQUESTS").font(Type.label).tracking(0.9).foregroundColor(Palette.faint)
                Image(systemName: store.prsExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Palette.faint)
                Spacer()
                if !store.prs.isEmpty {
                    Text("\(store.prs.count) open").font(Type.numSmall).foregroundColor(Palette.faint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if !store.prsExpanded, !store.prs.isEmpty {
            // Folded: one line per state, worst first, e.g. "1 checks failing · 6 awaiting review".
            let byState = Dictionary(grouping: store.prs, by: \.state).sorted { $0.key < $1.key }
            HStack(spacing: 0) {
                ForEach(Array(byState.enumerated()), id: \.element.key) { i, group in
                    if i > 0 { Text(" · ").font(Type.small).foregroundColor(Palette.faint) }
                    Text("\(group.value.count) \(group.key.label)").font(Type.small).foregroundColor(prColor(group.key))
                }
            }
            .padding(.horizontal, 6)
        }
        if store.prs.isEmpty {
            Text(store.prErrors.first ?? "Nothing open").font(Type.small).foregroundColor(Palette.dim)
        }
        let shownActive = showAllActivePRs ? Array(active) : Array(active.prefix(Config.prRowsLimit))
        if store.prsExpanded {
        VStack(spacing: 1) {
            ForEach(shownActive) { pr in prRow(pr) }
            if active.count > Config.prRowsLimit {
                disclosure(showAllActivePRs ? "Show fewer" : "+\(active.count - Config.prRowsLimit) more",
                           open: showAllActivePRs) { showAllActivePRs.toggle() }
            }
            // Open PRs that need nothing from the user right now, one toggle per state,
            // e.g. "7 awaiting review (api)"; each expands to clickable rows.
            ForEach(Dictionary(grouping: parked, by: \.state).sorted { $0.key < $1.key }, id: \.key) { state, items in
                let repos = Set(items.map(\.repo)).sorted().joined(separator: ", ")
                let open = openPRGroups.contains(state.rawValue)
                disclosure("\(items.count) \(state.label) (\(repos))", open: open) {
                    if open { openPRGroups.remove(state.rawValue) } else { openPRGroups.insert(state.rawValue) }
                }
                if open {
                    ForEach(items) { pr in prRow(pr) }
                }
            }
        }
        }
    }

    private func prRow(_ pr: PullRequest) -> some View {
        HoverRow(action: { NSWorkspace.shared.open(pr.url) }) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(prColor(pr.state)).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).font(Type.body).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text("\(pr.repo) #\(pr.number)").font(Type.numSmall).foregroundColor(Palette.faint)
                        Text(pr.state.label).font(Type.small).foregroundColor(prColor(pr.state))
                        Spacer(minLength: 0)
                        Text(ago(pr.updatedAt, now: store.now)).font(Type.numSmall).foregroundColor(Palette.faint)
                    }
                }
            }
        }
        .help("\(pr.title)\nby \(pr.author)")
    }

    private func disclosure(_ title: String, open: Bool, toggle: @escaping () -> Void) -> some View {
        HoverRow(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundColor(Palette.faint).frame(width: 8)
                Text(title).font(Type.small).foregroundColor(Palette.dim)
                Spacer(minLength: 0)
            }
        }
    }

    private func prColor(_ s: PRState) -> Color {
        switch s {
        case .failing: return Palette.bad
        case .reviewRequested, .changesRequested: return Palette.warn
        case .readyToMerge: return Palette.ok
        case .checksRunning: return Palette.busy
        case .awaitingReview, .draft: return Palette.faint
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionSection: some View {
        SectionLabel(title: "Claude sessions", trailing: sessionCountLabel(store.sessions))
        if let snap = store.restorable {
            restoreBanner(snap)
        }
        if store.sessions.isEmpty {
            Text("No live sessions").font(Type.small).foregroundColor(Palette.dim)
        }
        VStack(spacing: 1) {
            ForEach(store.sessions) { s in
                HoverRow(action: { TerminalFocus.focus(s) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        sessionRow(s)
                        if let agents = store.subagents[s.id] {
                            Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s") running: \(agents.map(\.description).joined(separator: ", "))")
                                .font(Type.small)
                                .foregroundColor(Palette.busy)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .padding(.leading, 14)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let claim = store.claims[s.id] {
                            Text(claim)
                                .font(Type.small)
                                .foregroundColor(Palette.dim)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 14)
                        }
                        if let q = store.questions[s.id] {
                            Text("asks: \(q)")
                                .font(Type.small)
                                .foregroundColor(Palette.warn)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .padding(.leading, 14)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let why = store.waitReasons[s.id] {
                            Text(why.summary)
                                .font(Type.small)
                                .foregroundColor(Palette.warn)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .padding(.leading, 14)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                    .help(s.cwd)
                if let st = store.handoffStatus[s.id] {
                    Text(st)
                        .font(Type.small)
                        .foregroundColor(Palette.busy)
                        .lineLimit(2)
                        .padding(.leading, 20)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.handedOff.contains(String(s.id.prefix(8))) {
                    Text(store.subagents[s.id] == nil
                         ? "Handed off; you can close this tab once it says it is done."
                         : "Handed off; relaying \(store.subagents[s.id]!.count) subagent result(s) to the new session.")
                        .font(Type.small)
                        .foregroundColor(Palette.faint)
                        .padding(.leading, 20)
                } else if let r = s.ctxRemaining, r <= Handoff.offerBelowRemaining, !s.isBackground {
                    Button("Hand off to a new session") { store.handoff(s) }
                        .controlSize(.small)
                        .padding(.leading, 20)
                        .help("Asks this session to write a handoff, then opens a new session with the same folder, account, model and effort that continues from it. This session stays open.")
                }
            }
        }
    }

    @ViewBuilder
    private func restartHelp(_ reasons: [String]) -> String {
        let why = "A restart would help: \(reasons.joined(separator: ", ")). Open Claude sessions are saved every minute and \(Config.appName) offers to reopen them afterwards."
        let check = store.restartCheck
        return check.safe
            ? why + "\n\nNothing is running right now: safe to restart."
            : why + "\n\nNot yet, a restart would interrupt:\n- " + check.blockers.joined(separator: "\n- ")
    }

    private func restoreBanner(_ snap: SessionSnapshot) -> some View {
        let foreground = snap.sessions.filter { $0.background != true }
        let background = snap.sessions.filter { $0.background == true }
        let interrupted = snap.sessions.filter { !($0.runningSubagents ?? []).isEmpty }
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(foreground.count) session\(foreground.count == 1 ? "" : "s") open before the restart")
                .font(Type.bodyMedium)
            Text(foreground.map(\.name).joined(separator: " · "))
                .font(Type.small).foregroundColor(Palette.dim).lineLimit(2)
            ForEach(interrupted, id: \.sessionId) { s in
                Text("Interrupted in \(s.name): \((s.runningSubagents ?? []).map(\.description).joined(separator: ", ")). These subagents do not restart by themselves; ask the session to re-run them.")
                    .font(Type.small).foregroundColor(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !background.isEmpty {
                Text("Background, not reopened: \(background.map(\.name).joined(separator: ", ")). `\(Config.cli) restore --dry-run` shows their resume commands.")
                    .font(Type.small).foregroundColor(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = store.restoreError {
                Text(err).font(Type.small).foregroundColor(Palette.bad).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Restore in Ghostty") { store.restoreSessions() }
                Button("Dismiss") { store.dismissRestore() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.busy.opacity(0.12)))
    }

    private func sessionRow(_ s: Session) -> some View {
        HStack(spacing: 8) {
            statusDot(s.status)
            Text(s.name)
                .font(Type.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(s.isBackground ? Palette.dim : Palette.text)
            Spacer(minLength: 4)
            if s.status == .waiting {
                Pill(text: "waiting \(ago(s.statusSince, now: store.now))", color: Palette.warn)
            } else if store.questions[s.id] != nil {
                Pill(text: "your turn \(ago(s.statusSince, now: store.now))", color: Palette.warn)
            }
            Text(s.profile.tag)
                .font(Type.label)
                .tracking(0.5)
                .foregroundColor(Palette.faint)
                .frame(width: 26)
            contextMeter(s.ctxRemaining)
        }
    }

    private func statusDot(_ st: SessionStatus) -> some View {
        let color: Color = {
            switch st {
            case .waiting: return Palette.warn
            case .busy, .shell: return Palette.busy
            case .idle, .unknown: return Palette.faint
            }
        }()
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    @ViewBuilder
    private func contextMeter(_ remaining: Double?) -> some View {
        if let r = remaining {
            let color = r <= Config.ctxCriticalRemaining ? Palette.bad
                : r <= Config.ctxWarnRemaining ? Palette.warn : Palette.dim
            HStack(spacing: 4) {
                Bar(fraction: r / 100, color: color, height: 3).frame(width: 28)
                Text("\(Int(r.rounded()))%")
                    .font(Type.numSmall)
                    .foregroundColor(color)
                    .frame(width: 26, alignment: .trailing)
            }
            .help("Context left")
        } else {
            Text("·").font(Type.numSmall).foregroundColor(Palette.faint).frame(width: 58, alignment: .trailing)
        }
    }


    // MARK: Usage

    @ViewBuilder
    private var usageSection: some View {
        SectionLabel(title: "Usage")
        VStack(spacing: 8) {
            ForEach(Config.profiles, id: \.self) { p in
                usageRow(p, store.usage.first { $0.profile == p })
            }
        }
        .padding(.horizontal, 6)
    }

    private func usageRow(_ p: Profile, _ u: AccountUsage?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(Type.bodyMedium)
                Text(u.map { "seen \(ago($0.observedAt, now: store.now)) ago" } ?? "no data yet")
                    .font(Type.small)
                    .foregroundColor(Palette.faint)
                if let c = u?.costToday, c > 0 {
                    Text(String(format: "$%.2f active", c))
                        .font(Type.small)
                        .foregroundColor(Palette.faint)
                        .help("Running cost of the sessions active today, each since it started, at API list prices. An estimate from Claude Code, not a bill.")
                }
            }
            .frame(width: 84, alignment: .leading)
            usageWindow("5h", u?.fiveHour, eta: u.flatMap { store.limitETA($0, window: "5h", $0.fiveHour) })
            usageWindow("7d", u?.sevenDay, eta: u.flatMap { store.limitETA($0, window: "7d", $0.sevenDay) })
        }
    }

    private func usageWindow(_ name: String, _ w: RateWindow?, eta: Date?) -> some View {
        let live = w.flatMap { $0.resetsAt > store.now ? $0 : nil }
        let used = live?.usedPercent ?? 0
        let color = Palette.load(used, warnAt: 60, badAt: Config.usageWarnUsed)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(name).font(Type.small).foregroundColor(Palette.dim)
                Spacer(minLength: 2)
                Text(live.map { "\(Int($0.usedPercent))%" } ?? "—").font(Type.num)
            }
            Bar(fraction: used / 100, color: color)
            if let eta {
                Text("limit ~\(clockTime(eta))")
                    .font(Type.small.weight(.semibold))
                    .foregroundColor(Palette.warn)
                    .lineLimit(1)
                    .help("At the recent rate this window reaches 100% at \(clockTime(eta)), before it resets in \(live.map { until($0.resetsAt, now: store.now) } ?? "?")")
            } else {
                Text(live.map { "resets \(until($0.resetsAt, now: store.now))" } ?? "reset")
                    .font(Type.small)
                    .foregroundColor(Palette.faint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Memory

    @ViewBuilder
    private var memorySection: some View {
        Button { store.memoryExpanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("MEMORY").font(Type.label).tracking(0.9).foregroundColor(Palette.faint)
                    Image(systemName: store.memoryExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Palette.faint)
                    Spacer()
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
                            .font(Type.numSmall)
                            .foregroundColor(store.swapHot ? Palette.warn : Palette.faint)
                    }
                }
                HStack(spacing: 10) {
                    Text("up \(formatDuration(store.macState.uptime))")
                    Text("pressure \(store.macState.pressure.label)")
                        .foregroundColor(store.macState.pressure == .normal ? Palette.faint : Palette.warn)
                }
                .font(Type.small)
                .foregroundColor(Palette.faint)
                .padding(.horizontal, 6)
                if let m = store.memory, m.totalBytes > 0 {
                    let frac = Double(m.usedBytes) / Double(m.totalBytes)
                    HStack(spacing: 8) {
                        Bar(fraction: frac, color: Palette.load(frac * 100, warnAt: 70, badAt: Config.memoryWarnUsed))
                        Text("\(formatBytes(m.usedBytes)) / \(formatBytes(m.totalBytes))")
                            .font(Type.num)
                            .fixedSize()
                    }
                    .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if store.memoryExpanded {
            let top = store.topApps.first?.bytes ?? 1
            VStack(spacing: 4) {
                ForEach(store.topApps) { a in
                    HStack(spacing: 8) {
                        Text(a.name).font(Type.body).lineLimit(1).truncationMode(.tail)
                        if a.processCount > 1 {
                            Text("\(a.processCount)").font(Type.numSmall).foregroundColor(Palette.faint)
                        }
                        Spacer(minLength: 4)
                        Bar(fraction: Double(a.bytes) / Double(top), color: Palette.busy.opacity(0.7), height: 3)
                            .frame(width: 50)
                        Text(formatBytes(a.bytes)).font(Type.num).frame(width: 44, alignment: .trailing)
                    }
                }
                if store.topApps.isEmpty {
                    Text("Reading…").font(Type.small).foregroundColor(Palette.dim)
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

extension PanelView {
    // MARK: Homelab

    @ViewBuilder
    var homelabSection: some View {
        Button { store.homelabExpanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text((Config.server?.title ?? "Server").uppercased()).font(Type.label).tracking(0.9).foregroundColor(Palette.faint)
                    Image(systemName: store.homelabExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Palette.faint)
                    Spacer()
                    homelabVerdict
                }
                if let h = store.homelab {
                    homelabMeters(h)
                } else if let err = store.homelabError {
                    Text("Unreachable: \(err)").font(Type.small).foregroundColor(Palette.warn).lineLimit(1)
                } else {
                    Text("Checking…").font(Type.small).foregroundColor(Palette.dim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if store.homelabExpanded, let h = store.homelab {
            homelabDetail(h)
        }
    }

    @ViewBuilder
    private var homelabVerdict: some View {
        if let h = store.homelab {
            let (text, color) = verdict(h)
            Pill(text: text, color: color)
        }
    }

    /// One-word read of the box: is it idle, fine, or struggling, and why.
    private func verdict(_ h: HomelabStatus) -> (String, Color) {
        if !h.guestsDown.isEmpty { return ("\(h.guestsDown.count) down", Palette.bad) }
        if (h.tempC ?? 0) >= (Config.server?.tempBadC ?? 90) { return ("hot", Palette.bad) }
        if h.memPct >= Config.memoryWarnUsed { return ("memory tight", Palette.bad) }
        if h.loadPct >= 100 { return ("overloaded", Palette.bad) }
        if h.loadPct >= 60 || h.memPct >= 70 || (h.tempC ?? 0) >= (Config.server?.tempWarnC ?? 80) {
            return ("busy", Palette.warn)
        }
        if h.loadPct < 10 && h.memPct < 50 { return ("underused", Palette.busy) }
        return ("healthy", Palette.ok)
    }

    private func homelabMeters(_ h: HomelabStatus) -> some View {
        VStack(spacing: 5) {
            meterRow(
                "mem",
                fraction: h.memPct / 100,
                color: Palette.load(h.memPct, warnAt: 70, badAt: Config.memoryWarnUsed),
                value: String(format: "%.1f / %.0fG", h.memUsedGB, h.memTotalGB)
            )
            meterRow(
                "cpu",
                fraction: h.loadPct / 100,
                color: Palette.load(h.loadPct, warnAt: 60, badAt: 100),
                value: String(format: "load %.1f / %d", h.load1, h.cores)
            )
            if let t = h.tempC {
                meterRow(
                    "temp",
                    fraction: t / 100,
                    color: Palette.load(t, warnAt: Config.server?.tempWarnC ?? 80, badAt: Config.server?.tempBadC ?? 90),
                    value: "\(Int(t))°C"
                )
            }
        }
        .padding(.horizontal, 6)
    }

    private func meterRow(_ name: String, fraction: Double, color: Color, value: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(Type.small).foregroundColor(Palette.dim).frame(width: 30, alignment: .leading)
            Bar(fraction: fraction, color: color)
            Text(value).font(Type.num).frame(width: 96, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func homelabDetail(_ h: HomelabStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let arc = h.arcGB, arc > 0 {
                    Text(String(format: "ZFS cache %.1fG (reclaimable)", arc))
                }
                Text(String(format: "disk %.0f%%", h.diskPct))
                Text("up \(Int(h.uptimeH / 24))d")
            }
            .font(Type.small)
            .foregroundColor(Palette.faint)

            if h.guests.isEmpty {
                Text("Per-guest breakdown needs the updated status script on the host.")
                    .font(Type.small)
                    .foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let top = h.guests.map(\.memGB).max() ?? 1
                ForEach(h.guests) { g in
                    HStack(spacing: 8) {
                        Circle().fill(g.running ? Palette.ok : Palette.bad).frame(width: 5, height: 5)
                        Text(g.name).font(Type.body).lineLimit(1)
                        Text(g.kind == "qemu" ? "vm" : g.kind).font(Type.label).foregroundColor(Palette.faint)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f%%", g.hostCpuPct))
                            .font(Type.numSmall)
                            .foregroundColor(g.hostCpuPct >= 25 ? Palette.warn : Palette.faint)
                            .frame(width: 30, alignment: .trailing)
                        Bar(fraction: g.memGB / max(top, 0.01), color: Palette.busy.opacity(0.7), height: 3)
                            .frame(width: 40)
                        Text(String(format: "%.1f/%.0fG", g.memGB, g.maxMemGB))
                            .font(Type.num)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .help("\(g.kind) \(g.id)")
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
