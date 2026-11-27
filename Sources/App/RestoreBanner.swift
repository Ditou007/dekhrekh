import SwiftUI

/// Offers to reopen the sessions that were open before the last restart.
struct RestoreBanner: View {
    @ObservedObject var store: Store
    let snapshot: SessionSnapshot

    var body: some View {
        let foreground = snapshot.sessions.filter { $0.background != true }
        let background = snapshot.sessions.filter { $0.background == true }
        let interrupted = snapshot.sessions.filter { !($0.runningSubagents ?? []).isEmpty }
        VStack(alignment: .leading, spacing: 4) {
            Text("\(foreground.count) session\(foreground.count == 1 ? "" : "s") open before the restart")
                .font(Fonts.bodyMedium)
            Text(foreground.map(\.name).joined(separator: " · "))
                .font(Fonts.small).foregroundColor(Palette.dim).lineLimit(2)
            ForEach(interrupted, id: \.sessionId) { s in
                Text("Interrupted in \(s.name): \((s.runningSubagents ?? []).map(\.description).joined(separator: ", ")). These subagents do not restart by themselves; ask the session to re-run them.")
                    .font(Fonts.small).foregroundColor(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !background.isEmpty {
                Text("Background, not reopened: \(background.map(\.name).joined(separator: ", ")). `\(Config.cli) restore --dry-run` shows their resume commands.")
                    .font(Fonts.small).foregroundColor(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = store.restoreError {
                Text(err).font(Fonts.small).foregroundColor(Palette.bad).lineLimit(2)
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
}
