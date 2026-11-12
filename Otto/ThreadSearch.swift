import SwiftUI

/// Finding an old message in the thread. One rule for what matches and what lights up:
/// case- and diacritic-insensitive in the reader's locale, so "perche" finds "perché".
enum ThreadSearch {
    static func matches(_ text: String, _ query: String) -> Bool { text.localizedStandardContains(query) }

    /// Every place `query` is in `text`, by the same rule as `matches`.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = [], from = text.startIndex
        while from < text.endIndex, let r = text[from...].localizedStandardRange(of: query), !r.isEmpty {
            found.append(r)
            from = r.upperBound
        }
        return found
    }

    /// What a result shows: the whole text, or when the first match is far in, from a few words
    /// before it, so the match is on screen and not cut off below the bubble's last line.
    static func excerpt(_ text: String, _ query: String) -> String {
        guard let first = ranges(of: query, in: text).first,
              text.distance(from: text.startIndex, to: first.lowerBound) > 80 else { return text }
        var start = text.index(first.lowerBound, offsetBy: -40)
        if let space = text[start..<first.lowerBound].firstIndex(where: \.isWhitespace) { start = text.index(after: space) }
        return "…" + text[start...]
    }
}

/// The field a pull down on the thread reveals, as in Messages and Mail, and the way out of it.
struct SearchBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search", text: $query)
                    .focused(focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Search messages")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, query.isEmpty ? 14 : 0)
            .frame(minHeight: 44)
            .glassEffect(.regular, in: .capsule)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .tint(.primary)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 16)
        .accessibilityAction(.escape, close)
        // A bar, like the header above it: its text grows only so far (the results below grow all the way).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// The messages that match, in thread order with the newest at the bottom, each under its date.
/// A tap goes to it in the thread.
struct SearchResults: View {
    let hits: [Message]
    let query: String
    /// The older history is still on its way, or didn't come.
    let loading: Bool
    let failed: Bool
    /// What the composer and keyboard cover.
    let bottomInset: CGFloat
    /// Who wrote it, for VoiceOver.
    let who: (Message) -> String
    let retry: () -> Void
    let open: (Message) -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if hits.isEmpty {
                Group {
                    if loading { searchingOlder } else if failed { couldntLoad } else { ContentUnavailableView.search(text: query) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, bottomInset)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        // Where the older ones go: above the rest.
                        if loading { searchingOlder } else if failed { couldntLoad }
                        ForEach(hits) { m in
                            SearchHit(message: m, query: query, who: who(m)) { open(m) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .accessibilityAction(.escape, close)
    }

    private var searchingOlder: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Searching older messages…")
        }
        .font(size: 13, relativeTo: .footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// The app's "Couldn't load · Retry", saying what didn't load.
    private var couldntLoad: some View {
        Button(action: retry) {
            (Text("Couldn’t load older messages\u{00A0}· ").foregroundStyle(.secondary) + Text("Retry").foregroundStyle(.blue))
                .multilineTextAlignment(.center)
                .hitSlop()
        }
        .buttonStyle(.plain)
        .font(size: 13, relativeTo: .footnote)
        .padding(.horizontal, 16)
        .accessibilityLabel("Couldn’t load older messages. Retry")
    }
}

/// One result: the message's bubble with each match bold on yellow, its date above it.
private struct SearchHit: View {
    let message: Message
    let query: String
    let who: String
    let open: () -> Void
    private var mine: Bool { message.from == .me || message.from == .terminal }

    private var text: AttributedString {
        let shown = ThreadSearch.excerpt(message.text, query)
        var a = AttributedString(shown)
        for r in ThreadSearch.ranges(of: query, in: shown) {
            guard let lit = Range(r, in: a) else { continue }
            // Black on yellow reads on both bubbles in both appearances; bold keeps it from resting on colour alone.
            a[lit].backgroundColor = .yellow
            a[lit].foregroundColor = .black
            a[lit].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(size: 11, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Text(text)
                    .font(.body.leading(.tight))
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(mine ? .white : .primary)
                    .padding(.horizontal, 14).padding(.vertical, 9.5)
                    .background(BubbleShape(mine: mine, tail: true).fill(mine ? .outgoingBubble : .incomingBubble))
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .padding(mine ? .leading : .trailing, 89)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(who), \(message.date.formatted(date: .long, time: .shortened)): \(message.text)")
        .accessibilityHint("Shows it in the conversation")
    }
}
