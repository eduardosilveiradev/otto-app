import SwiftUI
import UIKit
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

    enum State { case editing, sending, queued, failed }

    /// Pulls out the link, text and images. Safari hands over the page URL, plus its title
    /// as the item's text, which is noise next to the link.
    func load(_ items: [NSExtensionItem]) async {
        var parts: [String] = []
        for p in items.flatMap({ $0.attachments ?? [] }) {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = try? await p.loadData(UTType.image), let img = UIImage(data: data) { images.append(img) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL { parts.append(url.absoluteString) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { parts.append(s) }
            }
        }
        text = parts.joined(separator: "\n")
    }

    func send() {
        state = .sending
        let message = [note, text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        var ok = true
        if images.isEmpty {
            ok = ShareOutbox.put(text: message, jpeg: nil)
        } else {
            // The words ride along with the first photo, as a caption.
            for (i, img) in images.enumerated() {
                ok = ok && ShareOutbox.put(text: i == 0 ? message : "", jpeg: img.jpegData(compressionQuality: 0.85))
            }
        }
        guard ok else { state = .failed; return }
        // A running app answers at once; otherwise it sends when it next opens.
        var taken = false
        ShareOutbox.observe(ShareOutbox.ack) { taken = true }
        ShareOutbox.post(ShareOutbox.ping)
        Task {
            try? await Task.sleep(for: .seconds(1))
            if taken { finish(); return }
            state = .queued
            try? await Task.sleep(for: .seconds(1.5))
            finish()
        }
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
                if !model.images.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(model.images.indices, id: \.self) { i in
                                Image(uiImage: model.images[i]).resizable().scaledToFill()
                                    .frame(width: 90, height: 90).clipShape(.rect(cornerRadius: 10))
                            }
                        }
                    }
                }
                if !model.text.isEmpty {
                    Text(model.text).font(.callout).foregroundStyle(.secondary).lineLimit(6)
                }
                TextField("Add a message", text: $model.note, axis: .vertical)
                    .focused($focused)
                switch model.state {
                case .queued: Text("Otto will send it when the app next opens.").foregroundStyle(.secondary)
                case .failed: Text("Couldn't hand it to the app. Open Otto once, then try again.").foregroundStyle(.red)
                default: EmptyView()
                }
            }
            .navigationTitle("Otto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.finish() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { model.send() }
                        .disabled(model.state != .editing || (model.text.isEmpty && model.images.isEmpty && model.note.isEmpty))
                }
            }
        }
        .onAppear { focused = true }
    }
}
