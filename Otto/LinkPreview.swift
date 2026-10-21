import SwiftUI
import LinkPresentation
import CryptoKit

/// Metadata for links in the thread, fetched once per URL. Memory cache for scrolling, a Caches-dir archive for the next launch.
@MainActor enum LinkMeta {
    private static let cache = NSCache<NSString, LPLinkMetadata>()
    private static var inflight: [String: Task<LPLinkMetadata?, Never>] = [:]
    private static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "linkmeta")

    static func cached(_ url: URL) -> LPLinkMetadata? {
        let key = url.absoluteString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = try? Data(contentsOf: file(url)),
              let md = try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: data) else { return nil }
        cache.setObject(md, forKey: key)
        return md
    }

    static func load(_ url: URL) async -> LPLinkMetadata? {
        if let hit = cached(url) { return hit }
        let key = url.absoluteString
        let task = inflight[key] ?? Task { try? await LPMetadataProvider().startFetchingMetadata(for: url) }
        inflight[key] = task
        let md = await task.value
        inflight[key] = nil
        guard let md else { return nil }   // a failure caches nothing, so the next appearance retries
        cache.setObject(md, forKey: key as NSString)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: md, requiringSecureCoding: true) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file(url))
        }
        return md
    }

    private static func file(_ url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appending(path: "\(hash).plist")
    }
}

/// LPLinkView in SwiftUI — the exact card Messages draws. Handles its own tap (opens the link).
struct LinkPreview: UIViewRepresentable {
    let metadata: LPLinkMetadata
    func makeUIView(context: Context) -> LPLinkView { LPLinkView(metadata: metadata) }
    func updateUIView(_ v: LPLinkView, context: Context) { v.metadata = metadata }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LPLinkView, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: min(proposal.width ?? 280, 280), height: .greatestFiniteMagnitude))
    }
}
