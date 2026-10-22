import SwiftUI

/// One agent's thread: messages between roles and you, tool calls behind a toggle.
struct CrewThreadView: View {
    let id: String
    @Environment(OttoStore.self) private var store
    @AppStorage("crewShowTools") private var showTools = false
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
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { card = true } label: {
                    VStack(spacing: 2) {
                        if let agent { CrewAvatar(agent: agent, size: 40) }
                        Text(crewName(id)).font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the contact card")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show tool calls", isOn: $showTools)
                    Button("Stop", role: .destructive) { Task { await store.crew.stop(id) } }
                        .disabled(agent?.status != "working")
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
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
            if !mine, let from = e.from, !sameRun {
                if from != id { caption(crewName(from)) }
                else if let to = e.to, to != "user" { caption("to \(crewName(to))") }
            }
            Text(e.text ?? "")
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

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(crewName(id))", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color(.systemGray6)))
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = ""
                Task { await store.crew.send(id, text: text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .tint(.blue)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}
