import PDFKit
import UIKit
import UniformTypeIdentifiers

enum Media {
    static func storeImage(_ image: UIImage) -> Attachment? {
        let resized = resized(image, maxSide: 1280)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let id = UUID()
        let file = "\(id.uuidString).jpg"
        do {
            try data.write(to: Paths.attachments.appendingPathComponent(file))
        } catch {
            return nil
        }
        return Attachment(id: id, kind: .image, name: "Photo", file: file)
    }

    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func engineImage(_ attachment: Attachment, maxSide: CGFloat = 896) -> EngineImage? {
        guard let url = attachment.fileURL, let image = UIImage(contentsOfFile: url.path) else { return nil }
        return engineImage(resized(image, maxSide: maxSide))
    }

    static func engineImage(_ image: UIImage) -> EngineImage? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return EngineImage(width: w, height: h, rgb: Data(rgb))
    }

    static let documentTypes: [UTType] = [.pdf, .plainText, .utf8PlainText, .sourceCode, .json, .commaSeparatedText, .xml, .html, .yaml, .text]
    static let documentLimit = 24_000

    static func document(_ url: URL) -> Attachment? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if let data = try? Data(contentsOf: url) {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        guard var content = text?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
        let truncated = content.count > documentLimit
        if truncated { content = String(content.prefix(documentLimit)) }
        return Attachment(id: UUID(), kind: .document, name: url.lastPathComponent, text: content, truncated: truncated)
    }

    static func prompt(for message: Message) -> String {
        let documents = message.attachments.filter { $0.kind == .document }
        let blocks = documents.map { doc in
            "File: \(doc.name)\(doc.truncated ? " (truncated)" : "")\n```\n\(doc.text ?? "")\n```"
        }
        let web = message.webContext.map { [$0, "Question:"] } ?? []
        let parts = blocks + web + [message.text]
        return parts.count == 1 ? message.text : parts.joined(separator: "\n\n")
    }
}
