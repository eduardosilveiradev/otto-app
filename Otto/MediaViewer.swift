import SwiftUI
import AVKit

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

    /// A video needs a file to play from: the bytes written once to caches, named by id.
    static func url(_ file: RemoteFile, from backend: any OttoBackend) async -> URL? {
        let ext = (file.name as NSString).pathExtension
        let url = URL.cachesDirectory.appending(path: "media-\(file.id).\(ext.isEmpty ? "mp4" : ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let d = await load(file, from: backend), (try? d.write(to: url)) != nil else { return nil }
        data[file.id] = nil   // the file holds it now; don't keep a second copy in memory
        return url
    }

    static var thumbs: [String: UIImage] = [:]
    /// The video's first frame, for the bubble.
    static func thumbnail(_ file: RemoteFile, from backend: any OttoBackend) async -> UIImage? {
        if let hit = thumbs[file.id] { return hit }
        guard let url = await url(file, from: backend) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        guard let cg = try? await gen.image(at: .zero).image else { return nil }
        let img = UIImage(cgImage: cg); thumbs[file.id] = img
        return img
    }
}

/// One photo in the thread, yours (the JPEG you sent) or Otto's (fetched on demand).
struct MediaItem: Identifiable {
    let id: String
    let date: Date
    let mine: Bool
    let local: Data?
    let file: RemoteFile?
    var isVideo: Bool { file?.kind == "video" }

    /// Every photo in the thread, oldest first, the order you swipe through them.
    static func all(in messages: [Message]) -> [MediaItem] {
        messages.flatMap { m -> [MediaItem] in
            var out: [MediaItem] = []
            if let img = m.image { out.append(MediaItem(id: m.id.uuidString, date: m.date, mine: m.from == .me, local: img, file: nil)) }
            for f in m.files ?? [] where f.kind == "image" || f.kind == "video" {
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
    @State private var sharing: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(abs(drop) / 400, 0.7)).ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(items) { item in
                    Group {
                        if item.isVideo { VideoPage(item: item, store: store, showing: current == item.id) }
                        else { MediaPage(item: item, store: store, zoomed: current == item.id ? $zoomed : .constant(false)) }
                    }
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
            ShareSheet(items: [$0.item]).presentationDetents([.medium, .large])
        }
    }

    private struct Shared: Identifiable { let id = UUID(); let item: Any }

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
                    let item = items[i]
                    Task {
                        if item.isVideo, let f = item.file { sharing = await MediaCache.url(f, from: store.backend) }
                        else { sharing = await MediaPage.image(item, store: store) }
                    }
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

/// One video: a spinner while it downloads, then the system player. It plays while it's the page on screen.
private struct VideoPage: View {
    let item: MediaItem
    let store: OttoStore
    let showing: Bool
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                Label("Couldn't load this video", systemImage: "exclamationmark.triangle").foregroundStyle(.white)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text("Loading video").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            guard let f = item.file, let url = await MediaCache.url(f, from: store.backend) else { failed = true; return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(url: url)
            if showing { player?.play() }
        }
        .onChange(of: showing) { _, on in if on { player?.play() } else { player?.pause() } }
        .onDisappear { player?.pause() }
    }
}
