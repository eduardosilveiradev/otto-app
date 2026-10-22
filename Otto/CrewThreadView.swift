import SwiftUI

/// One agent's thread: messages between roles and you, tool calls behind a toggle.
struct CrewThreadView: View {
    let id: String
    @Environment(OttoStore.self) private var store
    @AppStorage("crewShowTools") private var showTools = false
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    /// `-crewCard`: open on the contact card, for screenshots.
    @State private var card = ProcessInfo.processInfo.arguments.contains("-crewCard")

    private var agent: CrewAgent? { store.crew.agents.first { $0.id == id } }
    private var events: [CrewEvent] {
        (store.crew.threads[id] ?? []).filter { showTools || $0.kind != "tool" }
    }

    var body: some View {
        let list = events
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.key) { i, e in
                        let prev = i > 0 ? list[i - 1] : nil
                        if prev.map({ e.date.timeIntervalSince($0.date) > 3600 }) ?? true { Stamp(date: e.date) }
                        switch e.kind {
                        case "message":
                            let next = i + 1 < list.count ? list[i + 1] : nil
                            bubble(e, prev: prev, tail: next?.kind != "message" || next?.from != e.from)
                        case "tool": toolRow(e)
                        default: statusLine(e)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: list.count) { withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        // Otto's own header and composer, not the system bar: every thread looks like his.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $card) { CrewContactCard(id: id) }
        .task {
            store.crew.open = id
            await store.crew.load(id)
            store.crew.markSeen(id)
        }
        .onDisappear {
            if store.crew.open == id { store.crew.open = nil }
            store.crew.markSeen(id)
        }
        .onChange(of: store.crew.threads[id]?.count) { if store.crew.open == id { store.crew.markSeen(id) } }
    }

    @ViewBuilder private func bubble(_ e: CrewEvent, prev: CrewEvent?, tail: Bool) -> some View {
        let mine = e.from == "user"
        let sameRun = prev?.kind == "message" && prev?.from == e.from
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if !mine, let from = e.from, from != id, !sameRun { caption(crewName(from)) }
            Text(body(e))
                .font(.system(size: 17))
                .foregroundStyle(mine ? .white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(BubbleShape(mine: mine, tail: tail).fill(mine ? Color.blue : Color(.systemGray5)))
                .padding(mine ? .leading : .trailing, 48)
            if store.crew.failed.contains(e.key) {
                Text("Not delivered").font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.top, sameRun ? 0 : 8)
    }

    /// Its own message to someone else opens with a small grey "@Name", the way a mention reads.
    private func body(_ e: CrewEvent) -> AttributedString {
        var text = AttributedString(e.text ?? "")
        guard e.from == id, let to = e.to, to != "user" else { return text }
        var at = AttributedString("@\(crewName(to).replacing(" ", with: "")) ")
        at.font = .system(size: 14, weight: .medium)
        at.foregroundColor = .secondary
        text.insert(at, at: text.startIndex)
        return text
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
    }

    private func toolRow(_ e: CrewEvent) -> some View {
        Label("\(e.tool ?? "") \(e.summary ?? "")", systemImage: "hammer")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, design: .monospaced))
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(_ e: CrewEvent) -> some View {
        Text((e.status ?? "") + (e.note.map { " · \($0)" } ?? ""))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    /// Mirrors Otto's header (ChatView): glass back and menu buttons, the face with a name pill under it.
    private var header: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
                .accessibilityLabel("Messages")
                Spacer()
                Menu {
                    Toggle("Show tool calls", isOn: $showTools)
                    Button("Stop", role: .destructive) { Task { await store.crew.stop(id) } }
                        .disabled(agent?.status != "working")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
            }
            Button { card = true } label: {
                VStack(spacing: 4) {
                    if let agent { CrewAvatar(agent: agent, size: 56) }
                    HStack(spacing: 3) {
                        Text(crewName(id)).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .tint(.primary)
            .accessibilityHint("Opens the contact card")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .background(alignment: .top) {
            LinearGradient(colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Otto's composer, minus photos and voice: the crew only takes text for now.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("Text \(crewName(id))", text: $draft, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...6)
                .padding(.leading, 14).padding(.vertical, 8)
                .frame(minHeight: 36)
            if canSend {
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft = ""
                    Task { await store.crew.send(id, text: text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.blue)
                        .frame(width: 36, height: 36)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: canSend)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}
