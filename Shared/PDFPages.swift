import PDFKit
import UIKit

/// A PDF as pictures of its pages: how one travels to the Mac (the photo route) until files have a route
/// of their own. Otto reads the pages as it reads any photo.
enum PDFPages {
    /// The first `limit` pages, each at most 1400 px on its long side, and how many pages there are in all.
    /// Nothing for a file that isn't a PDF or is locked with a password.
    static func images(_ data: Data, limit: Int = 8) -> (pages: [UIImage], total: Int) {
        guard let doc = PDFDocument(data: data), !doc.isLocked else { return ([], 0) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let pages = (0..<min(doc.pageCount, limit)).compactMap { i -> UIImage? in
            // The page's own thumbnail (rotation and crop applied), then flattened to one pixel per point:
            // PDFKit may draw it at the screen's scale, and eight pages at 3x would not fit a share extension.
            guard let thumb = doc.page(at: i)?.thumbnail(of: CGSize(width: 1400, height: 1400), for: .mediaBox) else { return nil }
            return UIGraphicsImageRenderer(size: thumb.size, format: format).image { _ in thumb.draw(in: CGRect(origin: .zero, size: thumb.size)) }
        }
        return (pages, doc.pageCount)
    }

    /// "Ticket.pdf, 2 pages", or with the cap, "Report.pdf, the first 8 of 23 pages": what goes along as words.
    static func caption(_ name: String, shown: Int, total: Int) -> String {
        shown < total ? "\(name), the first \(shown) of \(total) pages" : "\(name), \(total == 1 ? "1 page" : "\(total) pages")"
    }
}
