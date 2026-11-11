import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Throwaway host for the share sheet's and the keyboard's real code, so their states can be
// driven on the simulator with launch arguments (nothing can tap it here). Not part of the app.
//   -scene share|keyboard   -server http://127.0.0.1:4599
//   share:    -slowLoad (the shared item never finishes loading)   -retryAfter <s> (Try again's action once)
//   keyboard: -retryAfter <s> (the retry chip's action once)

let args = ProcessInfo.processInfo.arguments
/// Outside a real keyboard the proxy has no document id (nil behind a non-optional UUID): one stands in.
let harnessDocID = UUID()
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

@main struct Harness: App {
    init() { ShareDirect.save(serverURL: arg("-server") ?? "http://127.0.0.1:4599", token: "lab-token-not-real") }
    var body: some Scene {
        WindowGroup {
            if arg("-scene") == "keyboard" { KeyboardHost().ignoresSafeArea(edges: .bottom) } else { ShareHost() }
        }
    }
}

struct ShareHost: View {
    @State private var model = ShareModel()
    var body: some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
            .sheet(isPresented: .constant(true)) { ShareView(model: model).interactiveDismissDisabled() }
            .task { await run() }
    }

    func run() async {
        model.finish = { print("harness: finish (the real sheet closes here)") }
        if args.contains("-slowLoad") {
            let p = NSItemProvider()
            p.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier, visibility: .all) { _ in nil }   // never calls back
            let item = NSExtensionItem(); item.attachments = [p]
            await model.load([item])
            return
        }
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: URL(string: "https://example.com/recipes/focaccia")! as NSURL, typeIdentifier: UTType.url.identifier)]
        await model.load([item])
        model.note = "For Saturday"
        try? await Task.sleep(for: .seconds(2.5))   // after the sheet is up and has focused the field, as a tap would be
        model.send()
        if let s = arg("-retryAfter").flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(s))
            print("harness: Try again, state \(model.state)")
            model.send()
        }
    }
}

struct KeyboardHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Host() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Host: UIViewController {
        let kb = KeyboardViewController()
        override func viewDidLoad() {
            super.viewDidLoad()
            // The real keyboard is see-through over the system's grey keyboard backdrop; this stands in for it.
            view.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1) }
            addChild(kb)
            kb.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(kb.view)
            NSLayoutConstraint.activate([
                kb.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                kb.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                kb.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
            kb.didMove(toParent: self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            let kb = kb
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                kb.model.otto = .composing
                kb.model.ask("Write my reply to this.")   // what the "Reply" chip does
                if let s = arg("-retryAfter").flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(s))
                    print("harness: retry chip, state \(kb.model.otto)")
                    kb.model.retryOtto()
                }
            }
        }
    }
}
