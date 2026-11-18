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
    /// The bubble grows into the set and shrinks back into place (the contact card's zoom).
    @Namespace private var zoom

    var body: some View {
        Button { if set == nil { tries += 1 } else { open = true } } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    CardHead(symbol: "book", kind: String(localized: "Study set")) {
                        if let set { Text(count(set)).font(size: 13, relativeTo: .footnote).lineLimit(1) }
                    }
                    Text(set?.title ?? (missing ? "No longer available" : "Study set"))
                        .font(size: 16, weight: .semibold, relativeTo: .callout).lineLimit(2).multilineTextAlignment(.leading).padding(.top, 6)
                    if let source = set?.source {
                        Text(source).font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
                    }
                }
                .padding([.horizontal, .top], 14)
                Divider().padding(.top, 12)
                Group {
                    if failed { Text.couldntLoad }
                    else { Text("Study").foregroundStyle(set == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.actionInk)) }
                }
                .font(size: 15, relativeTo: .subheadline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14)
            }
            .ottoCard()
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .matchedTransitionSource(id: file.id, in: zoom)
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
        .fullScreenCover(isPresented: $open) { if let set { StudyView(set: set).navigationTransition(.zoom(sourceID: file.id, in: zoom)) } }
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
    @State private var finished = 0

    var body: some View {
        let queue = run.queue ?? Array(cards.indices)
        VStack(spacing: 20) {
            Text("\(run.known.count) of \(cards.count) known").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText(value: Double(run.known.count)))
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
                    // To VoiceOver the card is a button that says which side is up and what a tap does.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(run.flipped ? "Answer: \(c.back)" : "Question: \(c.front)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(run.flipped ? "Shows the question" : "Shows the answer")
                    .accessibilityAction { run.flipped.toggle() }
                    .padding(.horizontal)
                    // The next card comes in from the right and the one done with goes left, like a pile being
                    // worked through; under Reduce Motion they cross-fade.
                    .id(queue.count * 1000 + i)
                    .transition(still ? .opacity : .asymmetric(insertion: .offset(x: 40).combined(with: .opacity),
                                                              removal: .offset(x: -40).combined(with: .opacity)))
                if run.flipped {
                    HStack(spacing: 12) {
                        Button { next(queue, knew: false) } label: { Text("Again").frame(maxWidth: .infinity) }.quietButton()
                        Button { next(queue, knew: true) } label: { Text("Knew it").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    }
                    .font(.headline).controlSize(.large).padding(.horizontal)
                } else {
                    Text("Tap to flip").font(.subheadline).foregroundStyle(.secondary).frame(height: 50)
                }
            } else {
                // The check bounces once as the pile runs out.
                ContentUnavailableView {
                    Label("All known", systemImage: "checkmark.circle").symbolEffect(.bounce, value: finished)
                } description: { Text(run.missed.isEmpty ? "First try." : "\(run.missed.count) took more than one go.") }
                .onAppear { finished += 1 }
                Button("Start over") { run = CardsRun() }
            }
        }
        .padding(.bottom)
        .symbolEffectsRemoved(still)
        .sensoryFeedback(.selection, trigger: run.seen)
    }

    private func next(_ queue: [Int], knew: Bool) {
        let i = queue[0]
        withAnimation(still ? .easeInOut(duration: 0.2) : .snappy) {
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
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var finished = 0

    var body: some View {
        ScrollView {
            // A ZStack, so the question going and the next coming overlap instead of stacking.
            ZStack(alignment: .topLeading) {
                Group {
                    if run.at < quiz.count { question(run.at) } else { score }
                }
                .id(run.at)
                // On to the next like a page turning sideways; under Reduce Motion a cross-fade.
                .transition(still ? .opacity : .asymmetric(insertion: .offset(x: 40).combined(with: .opacity),
                                                          removal: .offset(x: -40).combined(with: .opacity)))
            }
            .padding()
        }
        .symbolEffectsRemoved(still)
        // On the pane, which is there before any answer: on the Next button, which comes with the answer, it never fired.
        .sensoryFeedback(trigger: run.answered) { old, new in
            guard let (q, o) = new.first(where: { old[$0.key] == nil }) else { return nil }
            return quiz[q].answer == o ? .success : .error
        }
    }

    private func question(_ at: Int) -> some View {
        let q = quiz[at], picked = run.answered[at]
        return VStack(alignment: .leading, spacing: 14) {
            Text("\(at + 1) of \(quiz.count)").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            Text(q.q).font(size: 22, weight: .semibold, relativeTo: .title2)
            ForEach(q.options.indices, id: \.self) { o in
                Button { if picked == nil { withAnimation(.snappy) { run.answered[at] = o } } } label: {
                    HStack {
                        Text(q.options[o])
                        Spacer(minLength: 8)
                        // The right one's check draws itself in; the wrong pick gets a cross (and a shake, below).
                        if picked != nil, o == q.answer {
                            Image(systemName: "checkmark.circle").foregroundStyle(Color.greenInk)
                                .transition(still ? AnyTransition.opacity : AnyTransition(.symbolEffect(.drawOn)))
                        } else if o == picked {
                            Image(systemName: "xmark.circle").foregroundStyle(Color.redInk)
                                .transition(still ? AnyTransition.opacity : AnyTransition(.symbolEffect(.drawOn)))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .background(fill(o, q, picked), in: .rect(cornerRadius: 16, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.press)
                // A wrong pick shakes its head, side to side and still, over 0.4 s. The red and the cross say it too.
                .keyframeAnimator(initialValue: CGFloat(0), trigger: picked == o && o != q.answer && !still) { row, x in
                    row.offset(x: x)
                } keyframes: { _ in
                    // The trigger only ever turns on (a new question is a new row), so this never plays backwards.
                    KeyframeTrack {
                        SpringKeyframe(-9, duration: 0.08, spring: .snappy)
                        SpringKeyframe(8, duration: 0.09, spring: .snappy)
                        SpringKeyframe(-5, duration: 0.09, spring: .snappy)
                        SpringKeyframe(0, duration: 0.14, spring: .smooth)
                    }
                }
                .accessibilityValue(picked == nil ? "" : o == q.answer ? "Correct" : o == picked ? "Wrong" : "")
                .rise(o)
            }
            if let picked {
                if let why = q.why { Text(why).font(.callout).foregroundStyle(.secondary).rise(0) }
                Button { withAnimation(.snappy) { run.at += 1 } } label: {
                    Text(at + 1 < quiz.count ? "Next" : "See score").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .padding(.top, 6)
                .rise(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var score: some View {
        let right = run.answered.filter { quiz[$0.key].answer == $0.value }.count
        return VStack {
            // The star (all right) or the list bounces once as the score comes up.
            ContentUnavailableView {
                Label("\(right) / \(quiz.count)", systemImage: right == quiz.count ? "star.fill" : "checklist")
                    .symbolEffect(.bounce, value: finished)
            } description: { Text("Done sends the result to Otto.") }
            .onAppear { finished += 1 }
            Button("Try again") { withAnimation(.snappy) { run = QuizRun() } }.frame(maxWidth: .infinity)
        }
    }

    private func fill(_ o: Int, _ q: StudySet.Question, _ picked: Int?) -> Color {
        guard let picked else { return Color(.secondarySystemBackground) }
        if o == q.answer { return .greenTint }
        return o == picked ? .redTint : Color(.secondarySystemBackground)
    }
}
