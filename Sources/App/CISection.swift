import AppKit
import SwiftUI

struct CISection: View {
    @ObservedObject var store: Store

    var body: some View {
        PanelSection {
            SectionLabel(title: "CI", trailing: store.ci.first.map { "checked \(ago($0.checkedAt, now: store.now)) ago" })
            if store.ci.isEmpty {
                Text("Checking…").font(Fonts.small).foregroundColor(Palette.dim)
            }
            ForEach(store.ci) { repo in
                RepoCIRow(repo: repo, now: store.now)
            }
        }
    }
}

private struct RepoCIRow: View {
    let repo: RepoCI
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                icon
                Text(repo.label).font(Fonts.bodyMedium)
                Spacer()
                if repo.running > 0 {
                    Text("\(repo.running) running").font(Fonts.small).foregroundColor(Palette.busy)
                }
                if repo.queued > 0 {
                    Text("\(repo.queued) queued").font(Fonts.small).foregroundColor(Palette.dim)
                }
            }
            .padding(.horizontal, 6)
            if let err = repo.error {
                Text(err).font(Fonts.small).foregroundColor(Palette.warn).padding(.leading, 28)
            }
            ForEach(repo.failures) { run in
                FailedRunRow(run: run, now: now)
            }
        }
    }

    private var icon: some View {
        let (name, color) = status
        return Image(systemName: name).font(.system(size: 13)).foregroundColor(color).frame(width: 14)
    }

    private var status: (symbol: String, color: Color) {
        if repo.error != nil { return ("exclamationmark.circle.fill", Palette.warn) }
        if repo.failures.contains(where: { !$0.scheduled }) { return ("xmark.circle.fill", Palette.bad) }
        if !repo.failures.isEmpty { return ("moon.circle.fill", Palette.warn) }
        if repo.running + repo.queued > 0 { return ("circle.dotted.circle", Palette.busy) }
        return ("checkmark.circle.fill", Palette.ok)
    }
}

private struct FailedRunRow: View {
    let run: FailedRun
    let now: Date

    var body: some View {
        HoverRow(action: { NSWorkspace.shared.open(run.url) }) {
            HStack(spacing: 6) {
                Text(run.branch)
                    .font(Fonts.num)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(run.scheduled ? Palette.warn : Palette.text)
                Text(run.scheduled ? "nightly" : run.workflow)
                    .font(Fonts.small).foregroundColor(Palette.faint).lineLimit(1)
                Spacer(minLength: 4)
                Text(run.scheduled ? "next \(clockTime(run.nextScheduledRun))" : ago(run.finishedAt, now: now))
                    .font(Fonts.numSmall).foregroundColor(Palette.dim)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                    .foregroundColor(Palette.faint)
            }
            .padding(.leading, 22)
        }
        .help(helpText)
    }

    private var helpText: String {
        guard run.scheduled else { return "\(run.workflow) by \(run.actor). Open on GitHub" }
        return "\(run.workflow) failed \(ago(run.finishedAt, now: now)) ago. It stays failed until the next scheduled run (~\(clockTime(run.nextScheduledRun))) even if a fix has merged since. Open on GitHub"
    }
}
