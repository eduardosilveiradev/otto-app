import SwiftUI

/// Opens the full-screen media viewer on one photo: tapping any photo in the thread.
@MainActor @Observable
final class MediaViewer {
    static let shared = MediaViewer()
    /// The `MediaItem.id` it opens on; nil when closed. `-media`: open on the newest photo, for screenshots.
    var start: String? = ProcessInfo.processInfo.arguments.contains("-media") ? "" : nil
}

/// Photo bytes Otto sent, fetched once and shared by the bubble and the viewer.
@MainActor enum MediaCache {
    static var data: [String: Data] = [:]
    static func load(_ file: RemoteFile, from backend: any OttoBackend) async -> Data? {
        if let hit = data[file.id] { return hit }
        let d = await backend.file(file.id)
        if let d { data[file.id] = d }
        return d
    }
}

/// One photo in the thread, yours (the JPEG you sent) or Otto's (fetched on demand).
struct MediaItem: Identifiable {
    let id: String
    let date: Date
    let mine: Bool
    let local: Data?
    let file: RemoteFile?

    /// Every photo in the thread, oldest first, the order you swipe through them.
    static func all(in messages: [Message]) -> [MediaItem] {
        messages.flatMap { m -> [MediaItem] in
            var out: [MediaItem] = []
            if let img = m.image { out.append(MediaItem(id: m.id.uuidString, date: m.date, mine: m.from == .me, local: img, file: nil)) }
            for f in m.files ?? [] where f.kind == "image" {
                out.append(MediaItem(id: f.id, date: m.date, mine: m.from == .me, local: nil, file: f))
            }
            return out
        }
    }
}

/// Telegram-style: swipe sideways through every photo in the thread, pinch or double-tap
/// to zoom, drag down to close.
struct MediaViewerView: View {
    let store: OttoStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MediaItem] = []
    @State private var current: String?
    @State private var zoomed = false
    @State private var chrome = true
    @State private var drop: CGFloat = 0
    @State private var sharing: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(abs(drop) / 400, 0.7)).ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(items) { item in
                    MediaPage(item: item, store: store, zoomed: current == item.id ? $zoomed : .constant(false))
                        .tag(Optional(item.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: drop)
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        guard !zoomed, abs(v.translation.height) > abs(v.translation.width) else { return }
                        drop = v.translation.height
                    }
                    .onEnded { v in
                        if abs(drop) > 120 || abs(v.predictedEndTranslation.height) > 400 { dismiss() }
                        else { withAnimation(.snappy) { drop = 0 } }
                    },
                including: zoomed ? .subviews : .all
            )
            if chrome && drop == 0 { bar.transition(.opacity) }
        }
        .statusBarHidden(!chrome)
        .onAppear {
            items = MediaItem.all(in: store.messages)
            let start = MediaViewer.shared.start
            current = items.first { $0.id == start }?.id ?? items.last?.id
        }
        .onChange(of: current) { zoomed = false }
        .sheet(item: Binding(get: { sharing.map(Shared.init) }, set: { _ in sharing = nil })) {
            ShareSheet(items: [$0.image]).presentationDetents([.medium, .large])
        }
    }

    private struct Shared: Identifiable { let id = UUID(); let image: UIImage }

    private var bar: some View {
        let i = items.firstIndex { $0.id == current }
        return VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close")
                Spacer()
                if let i {
                    VStack(spacing: 1) {
                        Text("\(i + 1) of \(items.count)").font(.system(size: 15, weight: .semibold))
                        Text("\(items[i].mine ? "You" : "Otto") · \(items[i].date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
                Spacer()
                Button {
                    guard let i else { return }
                    Task { sharing = await MediaPage.image(items[i], store: store) }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Share")
            }
            .tint(.white)
            .padding(.horizontal, 16)
            Spacer()
        }
        .environment(\.colorScheme, .dark)
    }
}

/// One photo, zoomable. Panning only takes over once it's zoomed, so swipes page at 1×.
private struct MediaPage: View {
    let item: MediaItem
    let store: OttoStore
    @Binding var zoomed: Bool
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero

    static func image(_ item: MediaItem, store: OttoStore) async -> UIImage? {
        if let d = item.local { return UIImage(data: d) }
        guard let f = item.file, let d = await MediaCache.load(f, from: store.backend) else { return nil }
        return UIImage(data: d)
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .offset(pan)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(.rect)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = max(1, base * $0.magnification) }
                    .onEnded { _ in settle() }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { pan = CGSize(width: panBase.width + $0.translation.width, height: panBase.height + $0.translation.height) }
                    .onEnded { _ in panBase = pan; settle() },
                including: scale > 1 ? .all : .subviews
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if scale > 1 { scale = 1; pan = .zero } else { scale = 2.5 }
                }
                base = scale; panBase = pan; zoomed = scale > 1
            }
        }
        .task(id: item.id) { image = await Self.image(item, store: store) }
    }

    private func settle() {
        withAnimation(.snappy) {
            if scale <= 1.01 { scale = 1; pan = .zero }
        }
        base = scale; panBase = pan; zoomed = scale > 1
    }
}
