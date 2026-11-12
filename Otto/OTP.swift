import SwiftUI
import UniformTypeIdentifiers

/// A verification code from the server's OTP lane. Only ever on the live frame: history
/// and notifications carry the masked text, and the server's later edit takes it off.
struct OTPCode: Codable, Hashable {
    let code: String
    let sender: String?
}

/// The code's line in its bubble; a tap brings the drawer back.
struct OTPChip: View {
    let message: Message
    @Environment(OttoStore.self) private var store

    var body: some View {
        if let otp = message.otp {
            Button { store.otpDrawer = message } label: {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue)
                        .frame(width: 30, height: 30).background(Color.blue.opacity(0.12), in: .circle)
                    Text(String(repeating: "•", count: otp.code.count))
                        .font(size: 17, weight: .semibold, design: .rounded, relativeTo: .headline).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text("Show").font(size: 15, relativeTo: .subheadline).foregroundStyle(.blue)
                }
                .padding(10)
                .background(Color(.systemBackground).opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Verification code\(otp.sender.map { " from \($0)" } ?? ""). Show")
        }
    }
}

/// The drawer a fresh code opens in: one tile per character, big enough to read across
/// the room and type into another device, and a copy that clears itself off the clipboard.
struct OTPDrawer: View {
    let otp: OTPCode
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false
    @State private var copied = false
    /// Fits what's in it, so a large text size grows the drawer instead of clipping the button.
    @State private var height: CGFloat = 250

    var body: some View {
        VStack(spacing: 20) {
            Text(otp.sender.map { "Code from \($0)" } ?? "Verification code")
                .font(.headline)
            HStack(spacing: tiles > 6 ? 6 : 8) {
                ForEach(Array(otp.code.enumerated()), id: \.offset) { i, ch in tile(ch, at: i) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(otp.code.map(String.init).joined(separator: " "))

            Button(action: copy) {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .sensoryFeedback(.success, trigger: copied)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = max(250, $0 + 24) }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .onAppear { shown = true }
        .transaction { if UIAccessibility.isReduceMotionEnabled { $0.animation = nil } }
    }

    private var tiles: Int { otp.code.count }

    private func tile(_ ch: Character, at i: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Text(String(ch))
            .font(.system(size: tiles > 6 ? 28 : 34, weight: .semibold, design: .rounded).monospacedDigit())
            .frame(maxWidth: 52, minHeight: 64)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
            // Each tile settles in a beat after the one before it.
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .animation(.spring(response: 0.38, dampingFraction: 0.78).delay(Double(i) * 0.04), value: shown)
    }

    private func copy() {
        // Gone from the clipboard in two minutes, and never synced to the Mac's.
        UIPasteboard.general.setItems([[UTType.plainText.identifier: otp.code]],
                                      options: [.expirationDate: Date().addingTimeInterval(120), .localOnly: true])
        withAnimation(.snappy) { copied = true }
        Task { try? await Task.sleep(for: .seconds(0.6)); dismiss() }
    }
}
