import SwiftUI

struct SessionsSection: View {
    @ObservedObject var store: Store

    var body: some View {
        PanelSection {
            SectionLabel(title: "Claude sessions", trailing: sessionCountLabel(store.sessions))
            if let snap = store.restorable {
                RestoreBanner(store: store, snapshot: snap)
            }
            if store.sessions.isEmpty {
                Text("No live sessions").font(Fonts.small).foregroundColor(Palette.dim)
            }
            VStack(spacing: 1) {
                ForEach(store.sessions) { s in
                    SessionRow(store: store, session: s)
                }
            }
        }
    }
}

/// A session's clickable row, with the handoff or move action under it when one applies.
private struct SessionRow: View {
    @ObservedObject var store: Store
    let session: Session

    var body: some View {
        HoverRow(action: { TerminalFocus.focus(session) }) {
            VStack(alignment: .leading, spacing: 2) {
                SessionLine(session: session, asking: store.questions[session.id] != nil, now: store.now)
                if let agents = store.subagents[session.id] {
                    detail(Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s") running: \(agents.map(\.description).joined(separator: ", "))"),
                           color: Palette.busy)
                }
                if let claim = store.claims[session.id] {
                    Text(claim)
                        .font(Fonts.small)
                        .foregroundColor(Palette.dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 14)
                }
                if let q = store.questions[session.id] {
                    detail(Text("asks: \(q)"), color: Palette.warn)
                }
                if let why = store.waitReasons[session.id] {
                    detail(Text(why.summary), color: Palette.warn)
                }
            }
        }
        .help(session.cwd)
        handoff
        if store.handoffStatus[session.id] == nil, let target = store.moveTarget(session) {
            moveButton(to: target)
        }
    }

    private func detail(_ text: Text, color: Color) -> some View {
        text
            .font(Fonts.small)
            .foregroundColor(color)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.leading, 14)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var handoff: some View {
        if let status = store.handoffStatus[session.id] {
            Text(status)
                .font(Fonts.small)
                .foregroundColor(Palette.busy)
                .lineLimit(2)
                .padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.handedOff.contains(String(session.id.prefix(8))) {
            Text(handedOffNote)
                .font(Fonts.small)
                .foregroundColor(Palette.faint)
                .padding(.leading, 20)
        } else if let r = session.ctxRemaining, r <= Handoff.offerBelowRemaining, !session.isBackground {
            Button("Hand off to a new session") { store.handoff(session) }
                .controlSize(.small)
                .padding(.leading, 20)
                .help("Asks this session to write a handoff, then opens a new session with the same folder, account, model and effort that continues from it. This session stays open.")
        }
    }

    private var handedOffNote: String {
        guard let agents = store.subagents[session.id] else {
            return "Handed off; you can close this tab once it says it is done."
        }
        return "Handed off; relaying \(agents.count) subagent result(s) to the new session."
    }

    private func moveButton(to target: Profile) -> some View {
        let seen = Move.seen(target, store.usage)
        let help = "\(session.profile.title) is near its usage limit. Exits this session and resumes the same conversation on \(target.title) in a new Ghostty tab, same folder, model and effort. Only when the session is between turns."
        return Button("Continue on \(target.title)" + (seen ? "" : " (limits not seen)")) { store.move(session, to: target) }
            .controlSize(.small)
            .padding(.leading, 20)
            .help(help + (seen ? "" : " \(target.title) has not reported its limits yet; an account that is already out never does, so check it has room."))
    }
}

private struct SessionLine: View {
    let session: Session
    let asking: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(session.name)
                .font(Fonts.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(session.isBackground ? Palette.dim : Palette.text)
            Spacer(minLength: 4)
            if session.status == .waiting {
                Pill(text: "waiting \(ago(session.statusSince, now: now))", color: Palette.warn)
            } else if asking {
                Pill(text: "your turn \(ago(session.statusSince, now: now))", color: Palette.warn)
            }
            Text(session.profile.tag)
                .font(Fonts.label)
                .tracking(0.5)
                .foregroundColor(Palette.faint)
                .frame(width: 26)
            ContextMeter(remaining: session.ctxRemaining)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .waiting: return Palette.warn
        case .busy, .shell: return Palette.busy
        case .idle, .unknown: return Palette.faint
        }
    }
}

private struct ContextMeter: View {
    let remaining: Double?

    var body: some View {
        if let r = remaining {
            let color = color(for: r)
            HStack(spacing: 4) {
                Bar(fraction: r / 100, color: color, height: 3).frame(width: 28)
                Text("\(Int(r.rounded()))%")
                    .font(Fonts.numSmall)
                    .foregroundColor(color)
                    .frame(width: 26, alignment: .trailing)
            }
            .help("Context left")
        } else {
            Text("·").font(Fonts.numSmall).foregroundColor(Palette.faint).frame(width: 58, alignment: .trailing)
        }
    }

    private func color(for remaining: Double) -> Color {
        if remaining <= Config.ctxCriticalRemaining { return Palette.bad }
        if remaining <= Config.ctxWarnRemaining { return Palette.warn }
        return Palette.dim
    }
}
