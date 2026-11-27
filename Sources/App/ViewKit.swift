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

enum Fonts {
    static let title = Font.system(size: 12.5, weight: .semibold)
    static let body = Font.system(size: 12)
    static let bodyMedium = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 10.5)
    static let label = Font.system(size: 9.5, weight: .semibold)
    static let num = Font.system(size: 11, design: .monospaced)
    static let numSmall = Font.system(size: 10, design: .monospaced)
}

/// The padded column every panel section sits in.
struct PanelSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased()).font(Fonts.label).tracking(0.9).foregroundColor(Palette.faint)
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            SectionTitle(title: title)
            Spacer()
            if let trailing {
                Text(trailing).font(Fonts.numSmall).foregroundColor(Palette.faint)
            }
        }
    }
}

/// A section title with a fold chevron, for sections that open to show more.
struct FoldLabel<Trailing: View>: View {
    let title: String
    let expanded: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            SectionTitle(title: title)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(Palette.faint)
            Spacer()
            trailing
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
            .font(Fonts.small.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(filled ? color : Palette.dim)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(filled ? color.opacity(0.16) : Color.clear))
            .overlay(Capsule().stroke(filled ? Color.clear : Palette.border, lineWidth: 1))
    }
}
