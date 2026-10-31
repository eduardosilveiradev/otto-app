import SwiftUI
import LocalAuthentication

/// A change to Otto's own core that needs your say-so — the in-app version of typing
/// "i approve the otto core change". The server sends it (what, why, every file with its
/// tier, and a diff stat it computed itself); Approve sits behind Face ID. A payment
/// (`ask_payment`) rides the same screen: merchant, every line, the total and the card.
struct ApprovalRequest: Decodable, Identifiable, Hashable {
    struct File: Decodable, Hashable { let path: String; let tier: String; let why: String }
    struct Payment: Decodable, Hashable {
        struct Item: Decodable, Hashable { let name: String; let detail: String?; let quantity: Int; let unit: Double }
        let merchant: String
        let site: String?
        let items: [Item]
        let total: Double
        let currency: String
        let method: String
        let notes: [String]
        let test: Bool?
        func money(_ v: Double) -> String { v.formatted(.currency(code: currency)) }
    }
    let id: String
    let title: String
    let summary: String
    let files: [File]
    let branch: String?
    let stat: String?
    let expires: String?
    var payment: Payment? = nil
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
                if let p = request.payment { paymentRows(p) } else { changeRows }

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
                        Label(request.payment.map { "Pay \($0.money($0.total))" } ?? "Approve", systemImage: "faceid").frame(maxWidth: .infinity)
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

    @ViewBuilder private func paymentRows(_ p: ApprovalRequest.Payment) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.money(p.total)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Text(p.merchant).font(.headline)
                if let site = p.site { Text(site).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }

        Section {
            ForEach(Array(p.items.enumerated()), id: \.offset) { _, i in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.quantity > 1 ? "\(i.quantity) × \(i.name)" : i.name)
                        if let d = i.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    Text(p.money(i.unit * Double(i.quantity))).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Text("Total").fontWeight(.semibold)
                Spacer()
                Text(p.money(p.total)).fontWeight(.semibold).monospacedDigit()
            }
        } header: { Text("Items") }

        Section {
            Label(p.method, systemImage: "creditcard")
        } header: { Text("Paying with") }

        if !p.notes.isEmpty || p.test == true {
            Section {
                if p.test == true { Label("Test — nothing will be charged", systemImage: "testtube.2").foregroundStyle(.secondary) }
                ForEach(p.notes, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.subheadline) }
            } header: { Text("Before you pay") }
        }
    }

    @ViewBuilder private var changeRows: some View {
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
    }

    private func decide(_ approve: Bool) async {
        busy = true
        defer { busy = false }
        if approve {
            let ctx = LAContext()
            let reason = request.payment.map { "Pay \($0.money($0.total)) to \($0.merchant)" } ?? "Approve this change to Otto"
            do {
                // Face ID, falling back to the passcode: someone holding an unlocked phone still can't approve.
                guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return }
            } catch {
                failed = "Not approved — \(error.localizedDescription)"
                return
            }
        }
        await store.decide(request.id, approve: approve)
    }
}
