import LocalAuthentication
import SwiftUI

/// A tapped `crew:` button: the crew gathers round the orb, Face ID signs it off, each
/// member lights up in turn, and only then does the tap go to Otto. Starting the crew
/// spends real work, so it gets the same gate as approving a change to Otto.
struct CrewLaunch: View {
    let button: ActionButton
    /// The message the button sits under: what the crew is being asked to do.
    let summary: String
    let send: (ActionButton) -> Void

    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.ready
    @State private var lit = 0
    @State private var failed: String?

    enum Phase { case ready, authing, launching, done }

    var body: some View {
        let agents = store.crew.agents
        VStack(spacing: 20) {
            ZStack {
                MorphingOrb(state: phase == .ready || phase == .authing ? .composing : .solving,
                            size: .px64, displaySize: 112)
                ForEach(Array(agents.enumerated()), id: \.element.id) { i, a in
                    let angle = Double(i) / Double(max(agents.count, 1)) * 2 * .pi - .pi / 2
                    CrewAvatar(agent: a, size: 40)
                        .opacity(i < lit ? 1 : 0.3)
                        .scaleEffect(i < lit ? 1 : 0.86)
                        .offset(x: cos(angle) * 112, y: sin(angle) * 112)
                }
            }
            .frame(height: 290)
            .padding(.top, 28)

            VStack(spacing: 6) {
                Text(phase == .done ? "The crew's on it" : "Start the crew")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
                Text(summary)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(5)
            }
            .padding(.horizontal, 24)

            if let failed {
                Text(failed).font(.footnote).foregroundStyle(.red).padding(.horizontal, 24)
            }
            Spacer(minLength: 0)

            Button { Task { await launch() } } label: {
                Label(button.label.prefix(1).uppercased() + button.label.dropFirst(), systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(phase != .ready)
            .padding(.horizontal, 20)
            Button("Not now") { dismiss() }
                .disabled(phase == .launching || phase == .done)
                .padding(.bottom, 12)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(phase == .launching)
    }

    private func launch() async {
        failed = nil
        phase = .authing
        do {
            // Face ID, falling back to the passcode, as for approvals.
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Start the crew") else {
                phase = .ready
                return
            }
        } catch {
            failed = "Not started — \(error.localizedDescription)"
            phase = .ready
            return
        }
        phase = .launching
        let count = max(store.crew.agents.count, 1)
        for i in 1...count {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3)) { lit = i }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(130)) }
        }
        send(button)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { phase = .done }
        try? await Task.sleep(for: .milliseconds(900))
        dismiss()
    }
}

extension ActionButton {
    /// Buttons whose data starts `crew:` start crew work; the app gates them behind CrewLaunch.
    var startsCrew: Bool { data?.hasPrefix("crew:") == true }
}
