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
}

/// The bubble for a study set: what it is and how much is in it, like an iMessage app message.
struct StudyBubble: View {
    @Environment(OttoStore.self) private var store
    let file: RemoteFile
    @State private var set: StudySet?
    @State private var missing = false
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(set?.title ?? (missing ? "Study set — no longer available" : "Study set"))
                    .font(.system(size: 16, weight: .semibold)).lineLimit(2)
                if let set {
                    Text([set.source, count(set)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("Study").font(.system(size: 15, weight: .medium)).foregroundStyle(.blue).padding(.top, 6)
            }
            .frame(width: 230, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color(.systemGray5), in: .rect(cornerRadius: 18, style: .continuous))
        }
        .tint(.primary)
        .disabled(set == nil)
        .task(id: file.id) {
            guard set == nil, let d = await store.backend.file(file.id) else { missing = true; return }
            set = try? JSONDecoder().decode(StudySet.self, from: d)
            missing = set == nil
        }
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

    var body: some View {
        let queue = run.queue ?? Array(cards.indices)
        VStack(spacing: 20) {
            Text("\(run.known.count) of \(cards.count) known").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            if let i = queue.first {
                let c = cards[i]
                Text(run.flipped ? c.back : c.front)
                    .font(.system(size: run.flipped ? 20 : 26, weight: run.flipped ? .regular : .semibold))
                    .multilineTextAlignment(.center).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24, style: .continuous))
                    .rotation3DEffect(.degrees(run.flipped ? 180 : 0), axis: (0, 1, 0)).scaleEffect(x: run.flipped ? -1 : 1)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(.snappy) { run.flipped.toggle() } }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if run.at < quiz.count {
                    let q = quiz[run.at], picked = run.answered[run.at]
                    Text("\(run.at + 1) of \(quiz.count)").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    Text(q.q).font(.system(size: 22, weight: .semibold))
                    ForEach(q.options.indices, id: \.self) { o in
                        Button { if picked == nil { withAnimation(.snappy) { run.answered[run.at] = o } } } label: {
                            Text(q.options[o]).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 13)
                                .background(fill(o, q, picked), in: .rect(cornerRadius: 16, style: .continuous))
                        }.tint(.primary)
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
    Button(action: action) {
        Text(title).font(.headline).frame(maxWidth: .infinity).frame(height: 50)
            .background(color.opacity(0.18), in: .rect(cornerRadius: 16, style: .continuous))
            .foregroundStyle(color)
    }
}
