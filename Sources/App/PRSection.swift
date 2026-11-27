import AppKit
import SwiftUI

extension Palette {
    static func pr(_ s: PRState) -> Color {
        switch s {
        case .failing: return bad
        case .reviewRequested, .changesRequested: return warn
        case .readyToMerge: return ok
        case .checksRunning: return busy
        case .awaitingReview, .draft: return faint
        }
    }
}

struct PRSection: View {
    @ObservedObject var store: Store
    @ViewState private var showAllActive = false
    @ViewState private var openGroups: Set<Int> = []

    var body: some View {
        PanelSection {
            Button { store.prsExpanded.toggle() } label: {
                FoldLabel(title: "Pull requests", expanded: store.prsExpanded) {
                    if !store.prs.isEmpty {
                        Text("\(store.prs.count) open").font(Fonts.numSmall).foregroundColor(Palette.faint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !store.prsExpanded, !store.prs.isEmpty {
                foldedSummary
            }
            if store.prs.isEmpty {
                Text(store.prErrors.first ?? "Nothing open").font(Fonts.small).foregroundColor(Palette.dim)
            }
            if store.prsExpanded {
                expandedList
            }
        }
    }

    private var active: [PullRequest] { store.prs.filter(isActive) }
    private var parked: [PullRequest] { store.prs.filter { !isActive($0) } }

    private func isActive(_ pr: PullRequest) -> Bool {
        pr.state.needsYou || pr.state == .checksRunning
    }

    /// One line per state, worst first, e.g. "1 checks failing · 6 awaiting review".
    private var foldedSummary: some View {
        let byState = Dictionary(grouping: store.prs, by: \.state).sorted { $0.key < $1.key }
        return HStack(spacing: 0) {
            ForEach(Array(byState.enumerated()), id: \.element.key) { i, group in
                if i > 0 { Text(" · ").font(Fonts.small).foregroundColor(Palette.faint) }
                Text("\(group.value.count) \(group.key.label)").font(Fonts.small).foregroundColor(Palette.pr(group.key))
            }
        }
        .padding(.horizontal, 6)
    }

    private var expandedList: some View {
        let activeRows = active
        let shown = showAllActive ? activeRows : Array(activeRows.prefix(Config.prRowsLimit))
        return VStack(spacing: 1) {
            ForEach(shown) { pr in PRRow(pr: pr, now: store.now) }
            if activeRows.count > Config.prRowsLimit {
                DisclosureRow(title: showAllActive ? "Show fewer" : "+\(activeRows.count - Config.prRowsLimit) more",
                              open: showAllActive) { showAllActive.toggle() }
            }
            // Open PRs that need nothing from the user right now, one toggle per state,
            // e.g. "7 awaiting review (api)"; each expands to clickable rows.
            ForEach(Dictionary(grouping: parked, by: \.state).sorted { $0.key < $1.key }, id: \.key) { state, items in
                let repos = Set(items.map(\.repo)).sorted().joined(separator: ", ")
                let open = openGroups.contains(state.rawValue)
                DisclosureRow(title: "\(items.count) \(state.label) (\(repos))", open: open) {
                    if open { openGroups.remove(state.rawValue) } else { openGroups.insert(state.rawValue) }
                }
                if open {
                    ForEach(items) { pr in PRRow(pr: pr, now: store.now) }
                }
            }
        }
    }
}

private struct PRRow: View {
    let pr: PullRequest
    let now: Date

    var body: some View {
        HoverRow(action: { NSWorkspace.shared.open(pr.url) }) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Palette.pr(pr.state)).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).font(Fonts.body).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text("\(pr.repo) #\(pr.number)").font(Fonts.numSmall).foregroundColor(Palette.faint)
                        Text(pr.state.label).font(Fonts.small).foregroundColor(Palette.pr(pr.state))
                        Spacer(minLength: 0)
                        Text(ago(pr.updatedAt, now: now)).font(Fonts.numSmall).foregroundColor(Palette.faint)
                    }
                }
            }
        }
        .help("\(pr.title)\nby \(pr.author)")
    }
}

private struct DisclosureRow: View {
    let title: String
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        HoverRow(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundColor(Palette.faint).frame(width: 8)
                Text(title).font(Fonts.small).foregroundColor(Palette.dim)
                Spacer(minLength: 0)
            }
        }
    }
}
