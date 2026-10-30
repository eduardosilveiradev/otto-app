import SwiftUI

/// State the SwiftUI parts share with the controller.
@MainActor
final class BoardModel: ObservableObject {
    enum Mode { case keys, emoji, settings }
    enum Otto: Equatable { case closed, composing, thinking, done(String), failed(String) }
    struct Suggestion: Hashable { var text: String; var literal = false; var primary = false }

    @Published var mode: Mode = .keys
    @Published var otto: Otto = .closed
    @Published var prompt = ""
    @Published var suggestions: [Suggestion] = []
    @Published var settings = KeyboardSettings.load()
    @Published var dark = false

    var style: KeyStyle { settings.style.followsSystem ? .system(dark: dark) : settings.style }
    var barHeight: CGFloat { otto == .closed ? 44 : 92 }

    // Wired by the controller.
    var pick: (Suggestion) -> Void = { _ in }
    var ask: (String) -> Void = { _ in }
    var undoOtto: () -> Void = {}
    var typeEmoji: (String) -> Void = { _ in }
    var deleteBackward: () -> Void = {}
    var settingsChanged: () -> Void = {}
}

private extension RGBA { var color: Color { Color(uiColor: ui) } }

private func boardBackground(_ s: KeyStyle) -> some View {
    LinearGradient(colors: s.background.map(\.color), startPoint: .top, endPoint: .bottom)
}

// MARK: - the bar above the keys

struct TopBar: View {
    @ObservedObject var m: BoardModel

    var body: some View {
        let s = m.style
        VStack(spacing: 0) {
            if m.otto == .closed { suggestionRow(s) } else { ottoRows(s) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(s.text.color)
    }

    private func suggestionRow(_ s: KeyStyle) -> some View {
        HStack(spacing: 0) {
            Button { m.otto = .composing; m.prompt = "" } label: { OttoMark(size: 30) }
                .padding(.leading, 8).padding(.trailing, 4)
                .accessibilityLabel("Ask Otto")
            HStack(spacing: 0) {
                ForEach(Array(m.suggestions.prefix(3).enumerated()), id: \.offset) { i, sug in
                    if i > 0 { Rectangle().fill(s.text.color.opacity(0.18)).frame(width: 1, height: 24) }
                    Button { m.pick(sug) } label: {
                        Text(sug.literal ? "“\(sug.text)”" : sug.text)
                            .font(Font(s.uiFont(16, weight: sug.primary ? .semibold : .regular)))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(sug.primary ? RoundedRectangle(cornerRadius: 8).fill(s.key.color.opacity(0.7)).padding(4) : nil)
                            .contentShape(Rectangle())
                    }
                }
            }
            Button { m.mode = m.mode == .settings ? .keys : .settings } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 40, height: 44)
            }
            .accessibilityLabel("Keyboard settings")
        }
        .buttonStyle(.plain)
    }

    private func ottoRows(_ s: KeyStyle) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                OttoMark(size: 28, thinking: m.otto == .thinking)
                Group {
                    switch m.otto {
                    case .thinking: Text("Otto is on it…").opacity(0.7)
                    case .done(let what):
                        HStack { Text(what).lineLimit(1); Spacer(); Button("Undo") { m.undoOtto() }.fontWeight(.semibold) }
                    case .failed(let why): Text(why).font(.system(size: 13)).lineLimit(2).opacity(0.85)
                    default:
                        HStack(spacing: 1) {
                            Text(m.prompt.isEmpty ? "Ask Otto, or pick one below" : m.prompt)
                                .opacity(m.prompt.isEmpty ? 0.5 : 1).lineLimit(1).truncationMode(.head)
                            if !m.prompt.isEmpty { Caret(color: s.accent.color) }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .font(Font(s.uiFont(16)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 18).fill(s.key.color.opacity(0.85)))
                if m.otto == .composing, !m.prompt.isEmpty {
                    Button { m.ask(m.prompt) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(s.accent.color)
                    }
                }
                Button { m.otto = .closed } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 36)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.chips, id: \.0) { title, prompt in
                        Button { m.ask(prompt) } label: {
                            Text(title).font(Font(s.uiFont(14, weight: .medium)))
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(s.specialKey.color))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .disabled(m.otto == .thinking)
            .opacity(m.otto == .thinking ? 0.4 : 1)
        }
        .padding(.horizontal, 8).padding(.top, 6)
        .buttonStyle(.plain)
    }

    /// Quick asks. The ones starting "Rewrite" replace the text before the cursor; the rest insert.
    static let chips: [(String, String)] = [
        ("Reply", "Write my reply to this."),
        ("Fix", "Rewrite: fix spelling and grammar, change nothing else."),
        ("Shorter", "Rewrite: make it shorter."),
        ("Warmer", "Rewrite: make it warmer and friendlier."),
        ("→ EN", "Rewrite: translate it to English."),
        ("→ IT", "Rewrite: translate it to Italian."),
        ("→ PT", "Rewrite: translate it to Brazilian Portuguese."),
        ("Finish it", "Continue this where it stops."),
    ]
}

private struct Caret: View {
    var color: Color
    @State private var on = true
    var body: some View {
        Rectangle().fill(color).frame(width: 2, height: 20).opacity(on ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on = false } }
    }
}

/// Otto's tangerine face, small enough for a bar.
struct OttoMark: View {
    var size: CGFloat
    var thinking = false
    @State private var bob = false
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.74, blue: 0.4), Color(red: 1, green: 0.58, blue: 0.2)],
                                         startPoint: .top, endPoint: .bottom))
            HStack(spacing: size * 0.18) {
                Capsule().fill(Color(white: 0.12)).frame(width: size * 0.11, height: size * 0.22)
                Capsule().fill(Color(white: 0.12)).frame(width: size * 0.11, height: size * 0.22)
            }
            .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
        .offset(y: bob ? -2 : 0)
        .onChange(of: thinking, initial: true) {
            withAnimation(thinking ? .easeInOut(duration: 0.45).repeatForever() : .default) { bob = thinking }
        }
    }
}

// MARK: - emoji

struct EmojiPanel: View {
    @ObservedObject var m: BoardModel
    @State private var cat = 0
    @AppStorage("emojiRecents") private var recentsRaw = ""

    private var recents: [String] { recentsRaw.split(separator: " ").map(String.init) }

    var body: some View {
        let s = m.style
        let sets = [("clock", recents)] + Emoji.categories.map { ($0.icon, $0.items) }
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(38), spacing: 2), count: 5), spacing: 2) {
                        ForEach(sets.indices, id: \.self) { i in
                            ForEach(Array(sets[i].1.enumerated()), id: \.offset) { j, e in
                                Button { pick(e) } label: { Text(e).font(.system(size: 30)).frame(width: 42, height: 38) }
                                    .id(j == 0 ? "cat\(i)" : "\(i)-\(j)")
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: cat) { withAnimation { proxy.scrollTo("cat\(cat)", anchor: .leading) } }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 0) {
                Button { m.mode = .keys } label: { Text("ABC").font(Font(s.uiFont(15))).frame(width: 46, height: 36) }
                ForEach(sets.indices, id: \.self) { i in
                    if i > 0 || !recents.isEmpty {
                        Button { cat = i } label: {
                            Image(systemName: sets[i].0).font(.system(size: 15))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(cat == i ? Circle().fill(s.specialKey.color).frame(width: 30, height: 30) : nil)
                        }
                    }
                }
                Button { m.deleteBackward() } label: { Image(systemName: "delete.left").frame(width: 46, height: 36) }
            }
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(s.text.color)
    }

    private func pick(_ e: String) {
        m.typeEmoji(e)
        recentsRaw = ([e] + recents.filter { $0 != e }).prefix(30).joined(separator: " ")
    }
}

// MARK: - settings

struct SettingsPanel: View {
    @ObservedObject var m: BoardModel

    var body: some View {
        let s = m.style
        VStack(spacing: 0) {
            HStack {
                Text("Otto keyboard").font(Font(s.uiFont(17, weight: .semibold)))
                Spacer()
                Button("Done") { m.mode = .keys }.fontWeight(.semibold).foregroundStyle(s.accent.color)
            }
            .padding(.horizontal, 14).frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Languages · pick one or two") {
                        HStack(spacing: 8) {
                            ForEach(Lang.allCases, id: \.self) { l in
                                let on = m.settings.languages.contains(l)
                                Button { toggle(l) } label: {
                                    Text(l.name).font(Font(s.uiFont(14, weight: .medium)))
                                        .padding(.horizontal, 12).frame(height: 32)
                                        .background(Capsule().fill(on ? s.accent.color : s.key.color))
                                        .foregroundStyle(on ? .white : s.text.color)
                                }
                            }
                        }
                    }
                    section("Style") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(KeyStyle.presets, id: \.name) { p in
                                    Button { update { $0.style = p } } label: { Swatch(style: p, on: m.settings.style.name == p.name) }
                                }
                            }
                        }
                    }
                    section("Accent") {
                        HStack(spacing: 10) {
                            ForEach(KeyStyle.accents, id: \.self) { a in
                                Button { update { $0.style.accent = a; $0.style.followsSystem = false; $0.style.name = "Custom" } } label: {
                                    Circle().fill(a.color).frame(width: 26, height: 26)
                                        .overlay(Circle().strokeBorder(s.text.color, lineWidth: m.settings.style.accent == a ? 2 : 0))
                                }
                            }
                        }
                    }
                    section("Keys") {
                        HStack {
                            Text("Roundness").font(.system(size: 14))
                            Slider(value: Binding(get: { m.settings.style.corner }, set: { v in update { $0.style.corner = v.rounded() } }), in: 0...16)
                                .tint(s.accent.color)
                        }
                        Picker("Font", selection: Binding(get: { m.settings.style.font }, set: { f in update { $0.style.font = f } })) {
                            ForEach(KeyStyle.Font.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                        }
                        .pickerStyle(.segmented)
                    }
                    section("Typing") {
                        toggle("Slide to type", \.swipe)
                        toggle("Autocorrect", \.autocorrect)
                        toggle("Auto-capitalisation", \.autoCapitalize)
                        toggle("“.” shortcut (double space)", \.doubleSpacePeriod)
                        toggle("Character preview", \.keyPopups)
                        toggle("Haptics", \.haptics)
                        toggle("Key clicks", \.clicks)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 16)
            }
        }
        .foregroundStyle(s.text.color)
        .buttonStyle(.plain)
        .background(boardBackground(s))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).opacity(0.6)
            c()
        }
    }

    private func toggle(_ title: String, _ kp: WritableKeyPath<KeyboardSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { m.settings[keyPath: kp] }, set: { v in update { $0[keyPath: kp] = v } }))
            .font(.system(size: 14)).tint(m.style.accent.color)
    }

    private func toggle(_ l: Lang) {
        update { s in
            if let i = s.languages.firstIndex(of: l) { if s.languages.count > 1 { s.languages.remove(at: i) } }
            else { s.languages = Array((s.languages + [l]).suffix(2)) }
        }
    }

    private func update(_ f: (inout KeyboardSettings) -> Void) {
        f(&m.settings)
        m.settings.save()
        m.settingsChanged()
    }
}

private struct Swatch: View {
    let style: KeyStyle
    let on: Bool
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                boardBackground(style)
                HStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        RoundedRectangle(cornerRadius: style.corner / 2).fill((i == 2 ? style.accent : style.key).color)
                            .frame(width: 14, height: 18)
                    }
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style.accent.color, lineWidth: on ? 2.5 : 0))
            Text(style.name).font(.system(size: 11))
        }
    }
}
