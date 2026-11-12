import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// "Otto" in the share sheet: what you shared, a line to add, Send. It goes to the app
/// through ShareOutbox, so it lands in the thread exactly as if you'd sent it there.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}

@MainActor @Observable
final class ShareModel {
    var text = ""
    var images: [UIImage] = []
    var note = ""
    var state = State.editing
    var finish: () -> Void = {}
    /// A failed send can go again as it is.
    var canSend: Bool { if case .failed = state { true } else { state == .editing } }

    enum State: Equatable { case editing, sending, sent, queued, failed(ServerProblem) }
    /// True until every attachment has been read: Send waits, so a photo still loading isn't left out.
    var loading = true
    /// Photos that couldn't be read, said under the preview rather than dropped without a word.
    var unreadable = 0

    /// At most 1600 px on the long side, decoded straight to that size: a full-size 24 MP photo
    /// decodes to ~96 MB, and two of them get the extension killed for memory mid-share. The app
    /// scales to 1600 px anyway (OttoStore.jpeg).
    static func downsampled(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Pulls out the link, text and images. Safari hands over the page URL, plus its title
    /// as the item's text, which is noise next to the link.
    func load(_ items: [NSExtensionItem]) async {
        loading = true
        defer { loading = false }
        var parts: [String] = []
        for p in items.flatMap({ $0.attachments ?? [] }) {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = try? await p.loadData(UTType.image), let img = Self.downsampled(data) { images.append(img) }
                else { unreadable += 1 }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL { parts.append(url.absoluteString) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { parts.append(s) }
            }
        }
        text = parts.joined(separator: "\n")
    }

    /// One id per item (the text, or each photo), made once and used by both the outbox and the
    /// direct path, so a retry or a fallback after a partial queue is deduped, not doubled.
    @ObservationIgnored private var itemIDs: [UUID] = []


    func send() {
        state = .sending
        let message = [note, text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        if itemIDs.isEmpty { itemIDs = (0..<max(1, images.count)).map { _ in UUID() } }
        var ok = true
        if images.isEmpty {
            ok = ShareOutbox.put(text: message, jpeg: nil, id: itemIDs[0])
        } else {
            // The words ride along with the first photo, as a caption.
            for (i, img) in images.enumerated() {
                ok = ok && ShareOutbox.put(text: i == 0 ? message : "", jpeg: img.jpegData(compressionQuality: 0.85), id: itemIDs[i])
            }
        }
        guard ok else {
            // No app group on this build: hand it to the server directly instead.
            Task {
                do throws(ServerProblem) {
                    try await ShareDirect.send(text: message, jpegs: images.compactMap { $0.jpegData(compressionQuality: 0.85) }, ids: itemIDs)
                    await sent()
                } catch {
                    state = .failed(error)
                }
            }
            return
        }
        // A running app answers at once; otherwise it sends when it next opens.
        var taken = false
        ShareOutbox.observe(ShareOutbox.ack) { taken = true }
        ShareOutbox.post(ShareOutbox.ping)
        Task {
            try? await Task.sleep(for: .seconds(1))
            if taken { await sent(); return }
            state = .queued
            try? await Task.sleep(for: .seconds(1.5))
            finish()
        }
    }

    /// Long enough to read "Sent" before the sheet goes.
    private func sent() async {
        state = .sent
        try? await Task.sleep(for: .seconds(0.8))
        finish()
    }
}

private extension NSItemProvider {
    func loadData(_ type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            _ = loadDataRepresentation(for: type) { data, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data) }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                // What's going, then your words, then how it went: one group each.
                Section {
                    if model.loading { busy("Getting what you shared…") }
                    if !model.images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(model.images.indices, id: \.self) { i in
                                    Image(uiImage: model.images[i]).resizable().scaledToFill()
                                        .frame(width: 90, height: 90).clipShape(.rect(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    if model.unreadable > 0 {
                        Text(model.unreadable == 1 ? "One photo couldn’t be read and won’t be sent." : "\(model.unreadable) photos couldn’t be read and won’t be sent.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if !model.text.isEmpty {
                        Text(model.text).font(.callout).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
                Section {
                    TextField("Add a message", text: $model.note, axis: .vertical)
                        .focused($focused)
                }
                if model.state != .editing {
                    Section {
                        switch model.state {
                        case .editing: EmptyView()
                        case .sending: busy("Sending to Otto…")
                        case .sent:
                            Label { Text("Sent") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        case .queued: Label("It goes to Otto next time you open the app.", systemImage: "tray.and.arrow.up").foregroundStyle(.secondary)
                        case .failed(let problem):
                            Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Button("Try again") { model.send() }
                        }
                    }
                }
            }
            .navigationTitle("Otto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.finish() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { model.send() }
                        .disabled(model.loading || !model.canSend || (model.text.isEmpty && model.images.isEmpty && model.note.isEmpty))
                }
            }
        }
        .onAppear { focused = true }
        // The keyboard goes, so the outcome isn't hidden behind it; VoiceOver hears it without hunting.
        .onChange(of: model.state) { _, state in
            switch state {
            case .sending: focused = false
            case .sent: AccessibilityNotification.Announcement("Sent").post()
            case .failed(let problem): AccessibilityNotification.Announcement(problem.message).post()
            default: break
            }
        }
    }

    private func busy(_ what: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(what).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
