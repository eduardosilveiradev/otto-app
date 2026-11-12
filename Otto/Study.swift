import SwiftUI

/// A study set Otto sends as a `<name>.study.json` attachment: cards to flip and a quiz,
/// both written from the user's own textbook page. Finishing one texts Otto the result,
/// so the next set can lean on what was missed.
struct StudySet: Codable {
    struct Card: Codable, Hashable { let front: String; let back: String }
    struct Question: Codable, Hashable { let q: String; let options: [String]; let answer: Int; let why: String? }
    let title: String
    let source: String?
    let cards: [Card]
    let quiz: [Question]

    static func isStudy(_ f: RemoteFile) -> Bool { f.name.hasSuffix(".study.json") }

    #if DEBUG
    /// For screenshots: `-studyThread` serves it, `-studyOpen cards|flipped|quiz` opens it on that pane.
    static var debugOpen: String? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-studyOpen").map { $0 + 1 < a.count ? a[$0 + 1] : "cards" }
    }
    static let demo = StudySet(title: "Photosynthesis", source: "Biology, p. 112", cards: [
        Card(front: "Where does photosynthesis happen?", back: "In the chloroplasts, mostly in the leaf’s mesophyll cells."),
        Card(front: "What does the light reaction make?", back: "ATP and NADPH, and oxygen as a by-product."),
        Card(front: "What is the Calvin cycle’s input?", back: "Carbon dioxide, fixed by RuBisCO into sugar."),
    ], quiz: [
        Question(q: "Which gas do plants release during photosynthesis?", options: ["Carbon dioxide", "Oxygen", "Nitrogen"], answer: 1,
                 why: "Splitting water in the light reaction frees oxygen."),
        Question(q: "Where is chlorophyll found?", options: ["Mitochondria", "Nucleus", "Chloroplasts"], answer: 2, why: nil),
    ])
    #endif
}

/// The bubble for a study set: what it is and how much is in it, like an iMessage app message.
struct StudyBubble: View {
    @Environment(OttoStore.self) private var store
    let file: RemoteFile
    @State private var set: StudySet?
    /// The server says it's gone (a 404).
    @State private var missing = false
    /// Anything else that kept it from loading: tap to retry, and it retries once the connection is back.
    @State private var failed = false
    @State private var tries = 0
    @State private var open = false

    var body: some View {
        Button { if set == nil { tries += 1 } else { open = true } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(set?.title ?? (missing ? "Study set — no longer available" : "Study set"))
                    .font(size: 16, weight: .semibold, relativeTo: .callout).lineLimit(2)
                if let set {
                    Text([set.source, count(set)].compactMap { $0 }.joined(separator: " · "))
                        .font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Group {
                    if failed { Text.couldntLoad }
                    else { Text("Study").foregroundStyle(.blue) }
                }
                .font(size: 15, weight: .medium, relativeTo: .subheadline).padding(.top, 6)
            }
            .frame(width: 230, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color(.systemGray5), in: .rect(cornerRadius: 18, style: .continuous))
        }
        .tint(.primary)
        .disabled(set == nil && !failed)
        .task(id: "\(file.id) \(tries)") {
            guard set == nil else { return }
            failed = false
            do {
                guard let d = try await store.backend.file(file.id) else { missing = true; return }
                set = try? JSONDecoder().decode(StudySet.self, from: d)
                failed = set == nil   // a file it can't read isn't gone either
                #if DEBUG
                open = set != nil && StudySet.debugOpen != nil
                #endif
            } catch { failed = !Task.isCancelled }
        }
        .onChange(of: store.connected) { if store.connected && failed { tries += 1 } }
        .fullScreenCover(isPresented: $open) { if let set { StudyView(set: set) } }
    }

    private func count(_ s: StudySet) -> String {
        [s.cards.isEmpty ? nil : "\(s.cards.count) cards", s.quiz.isEmpty ? nil : "\(s.quiz.count) questions"]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

struct StudyView: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let set: StudySet
    @State private var mode = 0
    @State private var cards = CardsRun()
    @State private var quiz = QuizRun()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !set.cards.isEmpty && !set.quiz.isEmpty {
                    Picker("", selection: $mode) { Text("Cards").tag(0); Text("Quiz").tag(1) }
                        .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                }
                if mode == 0 && !set.cards.isEmpty { CardsPane(cards: set.cards, run: $cards) }
                else { QuizPane(quiz: set.quiz, run: $quiz) }
            }
            .navigationTitle(set.title).navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .onAppear {
                if StudySet.debugOpen == "flipped" { cards.flipped = true }
                if StudySet.debugOpen == "quiz" { mode = 1; quiz.answered[0] = 0 }
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { report(); dismiss() }.bold().disabled(cards.seen == 0 && quiz.answered.isEmpty)
                }
            }
        }
    }

    /// One line back to Otto: the score and exactly what to go over again.
    private func report() {
        var parts: [String] = []
        if cards.seen > 0 { parts.append("cards \(cards.known.count)/\(set.cards.count)") }
        if !quiz.answered.isEmpty {
            parts.append("quiz \(quiz.answered.filter { set.quiz[$0.key].answer == $0.value }.count)/\(quiz.answered.count)")
        }
        let weak = cards.missed.map { set.cards[$0].front }
            + quiz.answered.filter { set.quiz[$0.key].answer != $0.value }.keys.sorted().map { set.quiz[$0].q }
        store.send("📚 \(set.title): \(parts.joined(separator: ", "))" + (weak.isEmpty ? "" : "\nto review: " + weak.joined(separator: " · ")))
    }
}

struct CardsRun {
    var queue: [Int]? = nil
    var flipped = false
    var known: Set<Int> = []
    var missed: Set<Int> = []
    var seen: Int { known.count + missed.count }
}

/// Flip a card, then say whether you knew it. Missed cards come back three cards later
/// until each one is known.
private struct CardsPane: View {
    let cards: [StudySet.Card]
    @Binding var run: CardsRun
    /// Reduce Motion: the card cross-fades to its other side instead of turning over.
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let queue = run.queue ?? Array(cards.indices)
        VStack(spacing: 20) {
            Text("\(run.known.count) of \(cards.count) known").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            if let i = queue.first {
                let c = cards[i]
                Text(run.flipped ? c.back : c.front)
                    .font(size: run.flipped ? 20 : 26, weight: run.flipped ? .regular : .semibold, relativeTo: .title2)
                    .multilineTextAlignment(.center).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24, style: .continuous))
                    .rotation3DEffect(.degrees(run.flipped && !still ? 180 : 0), axis: (0, 1, 0)).scaleEffect(x: run.flipped && !still ? -1 : 1)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(still ? .easeInOut(duration: 0.2) : .snappy) { run.flipped.toggle() } }
                    .padding(.horizontal)
                if run.flipped {
                    HStack(spacing: 12) {
                        bigButton("Again", .orange) { next(queue, knew: false) }
                        bigButton("Knew it", .green) { next(queue, knew: true) }
                    }.padding(.horizontal)
                } else {
                    Text("Tap to flip").font(.subheadline).foregroundStyle(.secondary).frame(height: 50)
                }
            } else {
                ContentUnavailableView("All known", systemImage: "checkmark.circle",
                                       description: Text(run.missed.isEmpty ? "First try." : "\(run.missed.count) took more than one go."))
                Button("Start over") { run = CardsRun() }
            }
        }
        .padding(.bottom)
        .sensoryFeedback(.selection, trigger: run.seen)
    }

    private func next(_ queue: [Int], knew: Bool) {
        let i = queue[0]
        withAnimation(.snappy) {
            run.flipped = false
            if knew { run.known.insert(i); run.queue = Array(queue.dropFirst()) }
            else {
                // Three cards later, not the end of the pile: at the end it read as a skip.
                var rest = Array(queue.dropFirst())
                rest.insert(i, at: min(3, rest.count))
                run.missed.insert(i); run.queue = rest
            }
        }
    }
}

struct QuizRun {
    var at = 0
    var answered: [Int: Int] = [:]
}

private struct QuizPane: View {
    let quiz: [StudySet.Question]
    @Binding var run: QuizRun
    @Environment(\.colorScheme) private var scheme
    /// As Pill and BigButton: the colour as is in dark mode, 40% toward black in light.
    private func ink(_ c: Color) -> Color { scheme == .dark ? c : c.mix(with: .black, by: 0.4) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if run.at < quiz.count {
                    let q = quiz[run.at], picked = run.answered[run.at]
                    Text("\(run.at + 1) of \(quiz.count)").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    Text(q.q).font(size: 22, weight: .semibold, relativeTo: .title2)
                    ForEach(q.options.indices, id: \.self) { o in
                        Button { if picked == nil { withAnimation(.snappy) { run.answered[run.at] = o } } } label: {
                            HStack {
                                Text(q.options[o])
                                Spacer(minLength: 8)
                                if picked != nil, o == q.answer { Image(systemName: "checkmark.circle.fill").foregroundStyle(ink(.green)) }
                                else if o == picked { Image(systemName: "xmark.circle.fill").foregroundStyle(ink(.red)) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .background(fill(o, q, picked), in: .rect(cornerRadius: 16, style: .continuous))
                        }
                        .tint(.primary)
                        .accessibilityValue(picked == nil ? "" : o == q.answer ? "Correct" : o == picked ? "Wrong" : "")
                    }
                    if let picked {
                        if let why = q.why { Text(why).font(.callout).foregroundStyle(.secondary) }
                        bigButton(run.at + 1 < quiz.count ? "Next" : "See score", .blue) { withAnimation(.snappy) { run.at += 1 } }
                            .padding(.top, 6)
                            .sensoryFeedback(picked == q.answer ? .success : .error, trigger: picked)
                    }
                } else {
                    let right = run.answered.filter { quiz[$0.key].answer == $0.value }.count
                    ContentUnavailableView("\(right) / \(quiz.count)", systemImage: right == quiz.count ? "star.fill" : "checklist",
                                           description: Text("Done sends the result to Otto."))
                    Button("Try again") { run = QuizRun() }.frame(maxWidth: .infinity)
                }
            }.padding()
        }
    }

    private func fill(_ o: Int, _ q: StudySet.Question, _ picked: Int?) -> Color {
        guard let picked else { return Color(.secondarySystemBackground) }
        if o == q.answer { return .green.opacity(0.3) }
        return o == picked ? .red.opacity(0.3) : Color(.secondarySystemBackground)
    }
}

private func bigButton(_ title: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
    BigButton(title: title, color: color, action: action)
}

private struct BigButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).frame(height: 50)
                .background(color.opacity(0.18), in: .rect(cornerRadius: 16, style: .continuous))
                // As Pill: the colour as is in dark mode, 40% toward black in light, to read on its pale fill.
                .foregroundStyle(scheme == .dark ? color : color.mix(with: .black, by: 0.4))
        }
    }
}
