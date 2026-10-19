import SwiftUI
import LocalAuthentication

/// A change to Otto's own core that needs your say-so — the in-app version of typing
/// "i approve the otto core change". The server sends it (what, why, every file with its
/// tier, and a diff stat it computed itself); Approve sits behind Face ID.
struct ApprovalRequest: Decodable, Identifiable, Hashable {
    struct File: Decodable, Hashable { let path: String; let tier: String; let why: String }
    let id: String
    let title: String
    let summary: String
    let files: [File]
    let branch: String?
    let stat: String?
    let expires: String?
}

enum ApprovalUpdate { case show(ApprovalRequest), done(String) }

struct ApprovalSheet: View {
    @Environment(OttoStore.self) private var store
    let request: ApprovalRequest
    @State private var busy = false
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.summary)
                        .font(.body)
                        .textSelection(.enabled)
                } header: { Text("What it does") }

                Section {
                    ForEach(request.files, id: \.path) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(f.path).font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                                Spacer(minLength: 4)
                                Text(f.tier)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(f.tier == "guarded" ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15), in: .capsule)
                                    .foregroundStyle(f.tier == "guarded" ? Color.orange : Color.secondary)
                            }
                            Text(f.why).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: { Text("Files") }

                if let stat = request.stat {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(stat).font(.system(.caption, design: .monospaced)).fixedSize()
                        }
                    } header: { Text(request.branch.map { "Diff against main · \($0)" } ?? "Diff") }
                }

                if let failed {
                    Section { Text(failed).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { store.hideApproval(request.id) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(role: .destructive) { Task { await decide(false) } } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { Task { await decide(true) } } label: {
                        Label("Approve", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .disabled(busy)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }

    private func decide(_ approve: Bool) async {
        busy = true
        defer { busy = false }
        if approve {
            let ctx = LAContext()
            do {
                // Face ID, falling back to the passcode: someone holding an unlocked phone still can't approve.
                guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Approve this change to Otto") else { return }
            } catch {
                failed = "Not approved — \(error.localizedDescription)"
                return
            }
        }
        await store.decide(request.id, approve: approve)
    }
}
