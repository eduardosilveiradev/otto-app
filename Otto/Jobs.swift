import SwiftUI

// Coding jobs: the agents Otto hands work to on the Mac. The list comes whole from GET /app/jobs and
// from the socket's "jobs" frame; a message names the jobs it started ("jobs": [id]) and each one
// draws as a card under that message's bubble. The actions on one are POST /app/jobs/<verb> {id, text}:
// answer, steer, stop, merge, and resolve for a pull request with conflicts. The wire shape is
// otto-core's WireJob (otto/codejobs.ts); the desktop app reads the same one (otto-desktop's src/jobs.js).

/// One job as the server sends it. Only the id and the state are required: everything else an older
/// or newer server leaves out or adds still decodes.
struct CodeJob: Identifiable, Hashable {
    struct Question: Hashable { var text: String; var answers: [String] = [] }
    struct Step: Decodable, Hashable { let ts: String; let text: String; var note: String? = nil }
    struct PR: Decodable, Hashable {
        let n: Int
        var title: String? = nil
        var url: String? = nil
        var add: Int? = nil
        var del: Int? = nil
        var files: Int? = nil
        /// GitHub's MERGEABLE, CONFLICTING or UNKNOWN; none from an older server, which doesn't block.
        var mergeable: String? = nil
        var base: String? = nil
        var checks: String? = nil
    }

    let id: String
    /// queued, running, waiting, review, done, input, merged, stopped or failed.
    var state: String
    var title = ""
    var project: String? = nil
    var branch: String? = nil
    var createdAt: String? = nil
    var startedAt: String? = nil
    var endedAt: String? = nil
    /// What it is doing now, or the last thing it said.
    var now: String? = nil
    var question: Question? = nil
    var steps: [Step] = []
    var pr: PR? = nil
    /// Finished jobs only: "2.1M Claude tokens · ~3% of the week".
    var cost: String? = nil

    /// Waiting on your answer: the only state that wears the tangerine mark.
    var needsYou: Bool { state == "input" }
    var working: Bool { state == "running" || state == "waiting" || state == "queued" }
    var over: Bool { state == "merged" || state == "stopped" || state == "failed" }
    /// Its pull request can go in: it's up for review and GitHub doesn't report conflicts.
    var canMerge: Bool { state == "review" && pr != nil && pr?.mergeable != "CONFLICTING" }
    var conflicts: Bool { state == "review" && pr?.mergeable == "CONFLICTING" }
}

extension CodeJob.Question: Decodable {
    private enum Keys: String, CodingKey { case text, answers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decode(String.self, forKey: .text)
        answers = (try? c.decodeIfPresent([String].self, forKey: .answers)) ?? []
    }
}

extension CodeJob: Decodable {
    private enum Keys: String, CodingKey { case id, state, title, project, branch, createdAt, startedAt, endedAt, now, question, steps, pr, cost }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ k: Keys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(String.self, forKey: .state)
        title = text(.title) ?? ""
        project = text(.project); branch = text(.branch)
        createdAt = text(.createdAt); startedAt = text(.startedAt); endedAt = text(.endedAt)
        now = text(.now); cost = text(.cost)
        question = (try? c.decodeIfPresent(Question.self, forKey: .question)) ?? nil
        steps = (try? c.decodeIfPresent([Step].self, forKey: .steps)) ?? []
        pr = (try? c.decodeIfPresent(PR.self, forKey: .pr)) ?? nil
    }
}

/// GET /app/jobs and the "jobs" frame. A job that won't decode is left out; the rest still arrive.
struct CodeJobs: Decodable {
    let jobs: [CodeJob]
    private enum Keys: String, CodingKey { case jobs }
    private struct Maybe: Decodable {
        let job: CodeJob?
        init(from decoder: Decoder) throws { job = try? CodeJob(from: decoder) }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        jobs = ((try? c.decodeIfPresent([Maybe].self, forKey: .jobs)) ?? []).compactMap(\.job)
    }
}

extension CodeJob {
    /// The state in a word or two, as the card and the sheet say it.
    var stateLabel: String {
        switch state {
        case "queued": String(localized: "Queued")
        case "running": String(localized: "Running")
        case "waiting": String(localized: "Waiting")
        case "review": String(localized: "Ready to review")
        case "done": String(localized: "Done")
        case "input": String(localized: "Needs you")
        case "merged": String(localized: "Merged")
        case "stopped": String(localized: "Stopped")
        case "failed": String(localized: "Failed")
        default: state.prefix(1).uppercased() + state.dropFirst()
        }
    }

    /// When it started or ended, and its pull request: "Started 14 minutes ago · PR #214".
    func meta(now date: Date = .now) -> String {
        var parts: [String] = []
        if let end = LiveBackend.date(endedAt), !working, !needsYou { parts.append(messageWhen(end)) }
        else if let start = LiveBackend.date(startedAt) { parts.append(String(localized: "Started \(start.formatted(.relative(presentation: .named)))")) }
        else if state == "queued" { parts.append(String(localized: "Waiting to start")) }
        if let pr { parts.append("PR #\(pr.n)") }
        return parts.joined(separator: " · ")
    }
}

/// What a job action came back with: the job as it now is, or the server's words for why not.
enum JobOutcome { case done(CodeJob?), failed(String) }
enum JobVerb: String { case answer, steer, stop, merge, resolve }

/// Every job the Mac knows about, by id. Whole lists replace it; an action's answer replaces one.
@MainActor @Observable
final class JobStore {
    private(set) var byID: [String: CodeJob] = [:]
    func set(_ jobs: [CodeJob]) { byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    func put(_ job: CodeJob) { byID[job.id] = job }
}

// MARK: - The card under a message

/// Where a job stands, at the right of its card's top line.
struct JobStateMark: View {
    let job: CodeJob
    var body: some View {
        if job.needsYou { NeedsMark() } else {
            HStack(spacing: 5) {
                if job.state == "running" { ProgressView().controlSize(.mini) }
                else if job.state == "done" || job.state == "merged" { Image(systemName: "checkmark").font(size: 11, weight: .semibold, relativeTo: .caption) }
                Text(job.stateLabel).font(size: 13, relativeTo: .footnote)
            }
            .foregroundStyle(job.state == "failed" ? Color.redInk : Color.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A job in the thread: what it is, where it stands, and the way into its sheet. One that needs you
/// shows its question, with the answers it offered as buttons.
struct JobCard: View {
    let job: CodeJob
    @Environment(OttoStore.self) private var store
    @State private var open = false
    @State private var answering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open = true } label: {
                VStack(alignment: .leading, spacing: 0) {
                    CardHead(symbol: "apple.terminal", kind: String(localized: "Job")) { JobStateMark(job: job) }
                    Text(job.title.isEmpty ? String(localized: "Coding job") : job.title)
                        .font(size: 16, weight: .semibold, relativeTo: .callout).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading).lineLimit(3).padding(.top, 6)
                    if job.needsYou, let q = job.question?.text, !q.isEmpty {
                        Text(q).font(size: 15, relativeTo: .subheadline).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading).lineLimit(4).padding(.top, 4)
                    }
                    // Its age moves with the clock, like the desktop's.
                    TimelineView(.periodic(from: .now, by: 30)) { tl in
                        Text(job.meta(now: tl.date)).font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary)
                            .monospacedDigit().lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the job")

            if job.needsYou, let answers = job.question?.answers, !answers.isEmpty {
                // The answers it offered, one tap each; anything else is typed in the sheet.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { answerButtons(answers) }
                    VStack(alignment: .leading, spacing: 8) { answerButtons(answers) }
                }
                .disabled(answering)
                .padding(.horizontal, 14).padding(.top, 12)
            }

            Divider().padding(.top, 12)
            Button { open = true } label: {
                Text("Open job").font(size: 15, relativeTo: .subheadline).foregroundStyle(Color.actionInk)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }
        .ottoCard()
        .sheet(isPresented: $open) { JobSheet(id: job.id).environment(store) }
        #if DEBUG
        // `-jobOpen <id>` opens that job's sheet, for screenshots.
        .onAppear { if UserDefaults.standard.string(forKey: "jobOpen") == job.id { open = true } }
        #endif
    }

    @ViewBuilder private func answerButtons(_ answers: [String]) -> some View {
        ForEach(Array(answers.prefix(3).enumerated()), id: \.offset) { i, a in
            let button = Button(a) {
                answering = true
                Task { _ = await store.jobAction(.answer, id: job.id, text: a); answering = false }
            }
            .font(size: 15, weight: .semibold, relativeTo: .subheadline)
            .buttonBorderShape(.capsule)
            // The first is what it suggested, so it gets the blue; the others stay beside it.
            if i == 0 { button.buttonStyle(.borderedProminent) } else { button.quietButton() }
        }
    }
}

// MARK: - The sheet

/// One job, whole: what was asked, where it stands, what it's said, its pull request, and what you
/// can do about it from here.
struct JobSheet: View {
    let id: String
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// An answer to its question, or a word to steer it with.
    @State private var text = ""
    @State private var busy: JobVerb?
    @State private var failed: String?
    @State private var confirming: JobVerb?

    private var job: CodeJob? { store.jobs.byID[id] }

    var body: some View {
        NavigationStack {
            Group {
                if let job { content(job) }
                else { ContentUnavailableView("Job not found", systemImage: "apple.terminal", description: Text("Your Mac no longer lists it.")) }
            }
            .navigationTitle("Job").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await store.refreshJobs() }
    }

    private func content(_ job: CodeJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.title.isEmpty ? String(localized: "Coding job") : job.title)
                        .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        if job.needsYou { NeedsMark() } else { Pill(text: job.stateLabel, tint: job.state == "failed" ? .red : .secondary) }
                        TimelineView(.periodic(from: .now, by: 30)) { tl in
                            Text([job.project, job.meta(now: tl.date)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }

                if job.needsYou, let q = job.question { question(job, q) }

                if let now = job.now, !now.isEmpty, job.question?.text != now {
                    Divider()
                    MarkdownText(text: now).textSelection(.enabled)
                }

                if let pr = job.pr { pullRequest(job, pr) }

                if !job.steps.isEmpty { steps(job.steps) }

                if let cost = job.cost, !cost.isEmpty { Text(cost).font(.footnote).foregroundStyle(.secondary) }

                if job.working { steer(job) }

                if let failed { Text(failed).font(.footnote).foregroundStyle(Color.redInk) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
        }
        .confirmationDialog(confirming == .merge ? "Merge PR #\(job.pr?.n ?? 0)?" : "Stop this job?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if confirming == .merge { Button("Merge pull request") { Task { await act(.merge) } } }
            else { Button("Stop job", role: .destructive) { Task { await act(.stop) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirming == .merge ? "It goes into \(job.pr?.base ?? "the base branch") on GitHub." : "The agent stops where it is. What it has pushed stays.")
        }
    }

    /// What it asked, the answers it offered, and room for your own.
    private func question(_ job: CodeJob, _ q: CodeJob.Question) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(q.text).textSelection(.enabled)
            if !q.answers.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { answers(q.answers) }
                    VStack(alignment: .leading, spacing: 8) { answers(q.answers) }
                }
            }
            field("Your answer", verb: .answer)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
        .disabled(busy != nil)
    }

    @ViewBuilder private func answers(_ answers: [String]) -> some View {
        ForEach(Array(answers.enumerated()), id: \.offset) { i, a in
            let button = Button(a) { Task { await act(.answer, text: a) } }.font(.subheadline.weight(.semibold)).buttonBorderShape(.capsule)
            if i == 0 { button.buttonStyle(.borderedProminent) } else { button.quietButton() }
        }
    }

    private func pullRequest(_ job: CodeJob, _ pr: CodeJob.PR) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title.map { "PR #\(pr.n) · \($0)" } ?? "PR #\(pr.n)").font(.subheadline.weight(.semibold))
                let facts = [pr.add.map { "\($0.formatted()) added" }, pr.del.map { "\($0.formatted()) removed" }, pr.files.map { $0 == 1 ? "1 file" : "\($0.formatted()) files" }, pr.checks.flatMap { $0.isEmpty ? nil : "checks \($0)" }].compactMap { $0 }
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).monospacedDigit() }
                if job.conflicts { Text("It has conflicts with \(pr.base ?? "its base branch").").font(.footnote).foregroundStyle(Color.ottoInk) }
            }
            HStack(spacing: 8) {
                if job.canMerge {
                    Button { confirming = .merge } label: { label("Merge", .merge) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                } else if job.conflicts {
                    Button { Task { await act(.resolve) } } label: { label("Resolve conflicts", .resolve) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }
                if let url = pr.url.flatMap(URL.init(string:)) {
                    Link(destination: url) { Text("Open on GitHub").font(.subheadline.weight(.semibold)) }.quietButton()
                }
            }
            .disabled(busy != nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func steps(_ steps: [CodeJob.Step]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What it did").font(.subheadline.weight(.semibold))
            // Newest first, the last twelve: the whole transcript lives on the Mac.
            ForEach(Array(steps.suffix(12).reversed().enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(LiveBackend.date(s.ts).map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.text).font(.subheadline)
                        if let n = s.note, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// While it works: a word for the agent, and the way to stop it.
    private func steer(_ job: CodeJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Tell it something", verb: .steer)
            Button(role: .destructive) { confirming = .stop } label: { label("Stop job", .stop) }
                .quietButton(ink: .redInk)
        }
        .disabled(busy != nil)
    }

    /// One line of text and its send button, for an answer or a steer.
    private func field(_ prompt: LocalizedStringKey, verb: JobVerb) -> some View {
        HStack(spacing: 8) {
            TextField(prompt, text: $text, axis: .vertical).lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.systemBackground).opacity(0.6), in: .rect(cornerRadius: 20, style: .continuous))
            Button { Task { await act(verb, text: text) } } label: {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(verb == .answer ? "Send answer" : "Send")
        }
    }

    private func label(_ title: LocalizedStringKey, _ verb: JobVerb) -> some View {
        ZStack {
            Text(title).opacity(busy == verb ? 0 : 1)
            if busy == verb { ProgressView().controlSize(.small) }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func act(_ verb: JobVerb, text sent: String? = nil) async {
        let words = sent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if verb == .answer || verb == .steer { guard let words, !words.isEmpty else { return } }
        busy = verb; failed = nil
        defer { busy = nil }
        if let why = await store.jobAction(verb, id: id, text: words) { failed = why } else if verb == .answer || verb == .steer { text = "" }
    }
}

#if DEBUG
extension CodeJob {
    /// `-jobsThread`: a job at work, one waiting on an answer and one up for review, for screenshots.
    static var demo: [CodeJob] {
        let iso = ISO8601DateFormatter()
        func at(_ minutesAgo: Double) -> String { iso.string(from: Date(timeIntervalSinceNow: -minutesAgo * 60)) }
        return [
            CodeJob(id: "demo-running", state: "running", title: "Compare three flat insurance quotes", project: "home-admin", branch: "otto/insurance-quotes",
                    createdAt: at(15), startedAt: at(14), now: "Reading the second quote’s exclusions.",
                    steps: [Step(ts: at(13), text: "Read the three PDFs"), Step(ts: at(6), text: "Built the comparison table", note: "Cover, excess, price per year")]),
            CodeJob(id: "demo-input", state: "input", title: "Rename the settings keys", project: "otto-app", branch: "otto/settings-keys",
                    createdAt: at(52), startedAt: at(50), now: "Waiting on your answer.",
                    question: Question(text: "The old keys are still read by the keyboard extension. Rename them there too, or keep reading both?", answers: ["Rename both", "Keep both"]),
                    steps: [Step(ts: at(48), text: "Renamed the keys in the app"), Step(ts: at(41), text: "Tests pass")]),
            CodeJob(id: "demo-review", state: "review", title: "Find a quieter walk to the office", project: "routes", branch: "otto/quiet-route",
                    createdAt: at(1500), startedAt: at(1499), endedAt: at(1493),
                    now: "**Take Elm Street.** Two minutes longer, and it skips the main road.\n\n- 14 minute walk\n- One crossing, with lights\n- Quiet until about 8:30",
                    steps: [Step(ts: at(1498), text: "Compared four routes"), Step(ts: at(1494), text: "Opened the pull request")],
                    pr: PR(n: 214, title: "A quieter default route", url: "https://github.com/example/routes/pull/214", add: 81, del: 4, files: 3, mergeable: "MERGEABLE", base: "main", checks: "passing")),
        ]
    }

    /// `-jobsThread worst`: what real jobs do to the card and the sheet. A long title and question with
    /// five answers and no dates; a state this build has never heard of with no title at all; a failure
    /// with a long error, thirty steps and a pull request in the thousands; a title that isn't Latin.
    static var worst: [CodeJob] {
        let iso = ISO8601DateFormatter()
        func at(_ minutesAgo: Double) -> String { iso.string(from: Date(timeIntervalSinceNow: -minutesAgo * 60)) }
        func step(_ n: Int) -> Step {
            let note: String? = n % 7 == 0 ? "1 failure, the same one" : nil
            return Step(ts: at(Double(4000 - n * 3)), text: "Step \(n): ran the suite again", note: note)
        }
        return [
            CodeJob(id: "worst-input", state: "input",
                    title: "Rename every settings key across the app, the keyboard extension, the share extension and the widget, keeping the old ones readable for two releases",
                    startedAt: "not a date",
                    question: Question(text: "The keyboard extension still reads the old keys from the shared defaults, and so does the widget when it draws before the app has run once after the update. Do you want them renamed everywhere now, or read under both names until the release after next?",
                                       answers: ["Rename them everywhere now and migrate stored values on first launch", "Read both", "Ask me again after the release", "Stop", "Something else"])),
            CodeJob(id: "worst-unknown", state: "paused-by-host"),
            CodeJob(id: "worst-failed", state: "failed", title: "Fix", project: "bartholomew-fitzgerald-northwind-industries-holdings-monorepo", branch: "otto/fix",
                    createdAt: at(4000), startedAt: at(3999), endedAt: at(3990),
                    now: "The thread stopped on an error: the test host could not be launched because the simulator runtime was missing, and after three retries the build service stopped answering.",
                    steps: (1...30).map(step),
                    pr: PR(n: 12481, title: "Fix the flaky delivery test by waiting for the socket to say it is open instead of sleeping for a second and hoping", url: "https://github.com/example/monorepo/pull/12481",
                           add: 12481, del: 1, files: 1, mergeable: "CONFLICTING", base: "release/2026.11", checks: "failing"),
                    cost: "2.1M Claude tokens · ~3% of the week"),
            CodeJob(id: "worst-script", state: "done", title: "設定キーの名前を変更する", project: "otto-app", createdAt: at(90), startedAt: at(89), endedAt: at(60)),
        ]
    }
}
#endif
