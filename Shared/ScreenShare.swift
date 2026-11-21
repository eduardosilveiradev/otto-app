import CoreImage
import Foundation
import ImageIO

/// Your screen for Otto during a talk. The broadcast extension (OttoScreen) keeps only the newest frame, as a
/// JPEG in the app group's `screen` folder; the app sends it on the talk socket while you speak. Everything about
/// a share lives in that one folder, so stopping is one removal. The two sides talk through Darwin notifications
/// (DictationBridge's post and observe) and two stamps, each side's "still here", so a side that dies is noticed.
enum ScreenShare {
    /// Extension → app.
    static let started = "dev.otto.screen.started"
    static let finished = "dev.otto.screen.finished"
    /// App → extension: finish the broadcast.
    static let stop = "dev.otto.screen.stop"

    /// At most one frame this often, written by the extension and sent by the app.
    static let every: TimeInterval = 2
    static let longEdge: CGFloat = 1600
    static let maxBytes = 1_500_000
    /// A side whose stamp is older than this is gone (the app killed, the extension out of memory).
    static let stale: TimeInterval = 10
    static let appAlive = "app-alive", extensionAlive = "extension-alive"

    /// The extension's bundle id: the app's plus `.screen`, so a re-signed build (SideStore rewrites ids) still finds it.
    static var extensionID: String { (Bundle.main.bundleIdentifier ?? "dev.otto.app") + ".screen" }

    static var dir: URL? { ShareOutbox.container?.appending(path: "screen", directoryHint: .isDirectory) }
    private static var file: URL? { dir?.appending(path: "frame.jpg") }

    /// Whether a frame is due, `last` being when the last one was written or sent.
    static func due(_ last: Date?, _ now: Date = .now) -> Bool { last.map { now.timeIntervalSince($0) >= every } ?? true }

    /// The screen downscaled so its long edge is at most 1600 px, as a JPEG under 1.5 MB: the quality steps down
    /// until it fits. Nil if even the lowest doesn't (it always has, a busy screen at 0.2 is a few hundred KB).
    static func jpeg(_ image: CIImage, context: CIContext, under cap: Int = maxBytes) -> Data? {
        let at0 = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let s = min(1, longEdge / max(at0.extent.width, at0.extent.height))
        let scaled = s < 1 ? at0.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1]) : at0
        let out = scaled.cropped(to: CGRect(x: 0, y: 0, width: (scaled.extent.width + 0.01).rounded(.down), height: (scaled.extent.height + 0.01).rounded(.down)))
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        for q in [0.7, 0.5, 0.35, 0.2] {
            let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            guard let d = context.jpegRepresentation(of: out, colorSpace: sRGB, options: [key: q]) else { return nil }
            if d.count < cap { return d }
        }
        return nil
    }

    /// A JPEG's size in pixels, from its header.
    static func size(_ jpeg: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// The newest frame, written whole or not at all, over the last one.
    @discardableResult static func write(_ jpeg: Data) -> Bool {
        guard let dir, let file else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? jpeg.write(to: file, options: .atomic)) != nil
    }

    /// When the newest frame was written, without reading it.
    static func frameDate() -> Date? { file.flatMap(modified) }

    /// The newest frame, if there is one.
    static func latest() -> (jpeg: Data, width: Int, height: Int, at: Date)? {
        guard let file, let at = modified(file), let d = try? Data(contentsOf: file), let s = size(d) else { return nil }
        return (d, s.width, s.height, at)
    }

    /// Sharing's over: the frame and both stamps, gone.
    static func clear() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    /// A side saying it's still here.
    static func stamp(_ name: String) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: dir.appending(path: name))
    }

    /// Seconds since a side last said so; nil if it never did (or sharing was cleared since).
    static func age(_ name: String) -> TimeInterval? { dir.flatMap { modified($0.appending(path: name)) }.map { Date.now.timeIntervalSince($0) } }

    private static func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
}
