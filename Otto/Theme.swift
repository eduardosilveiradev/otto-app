import SwiftUI

/// Otto's contact photo everywhere he appears: the same 3D orange face as the conversations list and
/// the thread's header. Typing shows as working, sleeping as asleep; the face draws its own blink and Zs,
/// and holds still under Reduce Motion.
struct OttoAvatar: View {
    var size: CGFloat = 44
    var thinking = false
    var asleep = false

    var body: some View {
        // Small faces play cached frames; large ones render live, for the eye transitions.
        FaceView(look: .otto.with(asleep ? .asleep : thinking ? .working : .rest), size: size, live: size > 32)
            .frame(width: size, height: size)
    }
}

// MARK: - Design tokens (design/ios-redesign-mockup.html)

/// The redesign's colour roles. Blue is for actions and nothing else: the system's own blue fills the one
/// button that commits, and `actionInk` is blue as text. Tangerine is Otto and what is waiting on you,
/// never a button's fill. Your side of the thread stays slate (`outgoingBubble`), and everything else is
/// the system's greys, so charts and glyphs are drawn in the text colour.
extension Color {
    private static func pair(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        func ui(_ hex: UInt32, _ a: CGFloat) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark, darkAlpha) : ui(light, lightAlpha) })
    }

    /// Tangerine as a fill: the "needs you" dot and badge.
    static let otto = pair(dark: 0xFF9230, light: 0xF08A1C)
    /// Tangerine as small text: clears 4.5:1 on white and on a card.
    static let ottoInk = pair(dark: 0xFF9230, light: 0xAD5200)
    /// Blue as text on any surface: a link, an action under a card. (A filled button uses `.blue`.)
    static let actionInk = pair(dark: 0x409CFF, light: 0x0063D1)
    /// Otto's cards in the thread, and a command block.
    static let card = pair(dark: 0x1C1C1E, light: 0xF2F2F5)
    /// Quoted text inside a card.
    static let well = pair(dark: 0x111113, light: 0xFFFFFF)
    /// A line Otto wrote down, inside its bubble: a code, a calendar event.
    static let chip = pair(dark: 0x000000, light: 0xFFFFFF, darkAlpha: 0.34, lightAlpha: 0.72)
    /// Red and green as small text and glyphs.
    static let redInk = pair(dark: 0xFF6961, light: 0xB81F14)
    static let greenInk = pair(dark: 0x30D158, light: 0x1A7F37)
    /// Status fills: a wrong and a right answer, a removed and an added line.
    static let redTint = pair(dark: 0xFF453A, light: 0xFF3B30, darkAlpha: 0.22, lightAlpha: 0.14)
    static let greenTint = pair(dark: 0x30D158, light: 0x34C759, darkAlpha: 0.2, lightAlpha: 0.16)
}

/// The tangerine mark for anything waiting on you: a dot and a word, never a filled capsule
/// (a tinted capsule reads as an orange button).
struct NeedsMark: View {
    var text = String(localized: "Needs you")
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.otto).frame(width: 7, height: 7)
            Text(text.prefix(1).uppercased() + text.dropFirst()).font(size: 13, weight: .semibold, relativeTo: .footnote).foregroundStyle(Color.ottoInk)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A glyph on a neutral disc, for the lines Otto writes down in a bubble (a code, a schedule, a memory).
/// Glyphs take the text colour; they never get one of their own.
struct GlyphDisc: View {
    let symbol: String
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(size: 14, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.primary)
            .frame(width: side, height: side).background(Color(.tertiarySystemFill), in: .circle)
            .accessibilityHidden(true)
    }
}

/// The top line of a card: what kind of thing it is, and where it stands.
struct CardHead<Trailing: View>: View {
    var symbol: String? = nil
    let kind: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(size: 12, weight: .semibold, relativeTo: .footnote) }
            Text(kind).font(size: 13, weight: .semibold, relativeTo: .footnote)
            Spacer(minLength: 8)
            trailing
        }
        .foregroundStyle(.secondary)
    }
}

extension CardHead where Trailing == EmptyView {
    init(symbol: String? = nil, kind: String) { self.init(symbol: symbol, kind: kind) { EmptyView() } }
}

extension View {
    /// One frame for what Otto sends as a card: a draft, a job, data, a study set.
    func ottoCard(width: CGFloat? = 288) -> some View {
        frame(maxWidth: width ?? .infinity, alignment: .leading)
            .background(Color.card, in: .rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// A neutral capsule button beside the blue one: grey fill, the text colour (or `ink`) on it.
    func quietButton(ink: Color = .primary) -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.secondary).foregroundStyle(ink)
    }
}
