import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One processed scan photo, kept in memory only (F1.1).
struct ScanPhoto: Identifiable, Equatable {
    let id = UUID()
    /// JPEG, longest edge ≤ 1568 px, no metadata.
    let jpeg: Data
    let width: Int
    let height: Int
    /// Small preview for the thumbnail strip.
    let thumbnail: UIImage
}

/// F1.1: shrinks photos before upload and strips all metadata (EXIF, GPS, XMP).
/// Nothing is written to disk.
enum ScanImageProcessor {
    static let maxEdge: CGFloat = 1568
    static let targetBytes = 500_000
    static let startQuality: CGFloat = 0.8

    enum ProcessError: Error { case unreadable, encodeFailed }

    /// From camera or Photos library data (HEIC, JPEG, PNG…).
    static func process(_ data: Data) throws -> ScanPhoto {
        guard let image = UIImage(data: data) else { throw ProcessError.unreadable }
        return try process(image)
    }

    static func process(_ image: UIImage) throws -> ScanPhoto {
        var edge = maxEdge
        // Lower the quality first, then the size, until it fits the target.
        while true {
            let rendered = render(image, maxEdge: edge)
            for quality in stride(from: startQuality, through: 0.45, by: -0.1) {
                let jpeg = try encode(rendered, quality: quality)
                if jpeg.count <= targetBytes || edge <= 640 && quality <= 0.5 {
                    let thumb = render(image, maxEdge: 160)
                    return ScanPhoto(jpeg: jpeg, width: rendered.width, height: rendered.height,
                                     thumbnail: UIImage(cgImage: thumb))
                }
            }
            edge = (edge * 0.8).rounded()
        }
    }

    /// Redraws the image upright (camera orientation baked in) at ≤ `maxEdge`, never upscaling.
    /// Redrawing produces a fresh bitmap with no metadata attached.
    static func render(_ image: UIImage, maxEdge: CGFloat) -> CGImage {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let out = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return out.cgImage!
    }

    /// JPEG with only the compression setting: no EXIF, GPS, TIFF or XMP dictionaries.
    static func encode(_ image: CGImage, quality: CGFloat) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProcessError.encodeFailed
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ProcessError.encodeFailed }
        // ImageIO still adds its own small EXIF block (pixel size, color space); remove it so
        // the upload carries no EXIF at all.
        return stripMetadataSegments(out as Data)
    }

    /// Removes APP1 (EXIF, XMP), APP13 (IPTC) and comment segments from a JPEG's header.
    /// Image data, JFIF (APP0), ICC color (APP2) and Adobe (APP14) segments are kept.
    static func stripMetadataSegments(_ jpeg: Data) -> Data {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return jpeg }
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA { break }   // start of scan: the rest is image data
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { return jpeg }
            let drop = marker == 0xE1 || marker == 0xED || marker == 0xFE
            if !drop { out.append(contentsOf: b[i..<(i + 2 + len)]) }
            i += 2 + len
        }
        out.append(contentsOf: b[i...])
        return Data(out)
    }

    /// Metadata dictionaries present in a JPEG (used by tests and the debug check).
    static func metadataKeys(_ jpeg: Data) -> Set<String> {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        let keys: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                                kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
        return Set(keys.map { $0 as String }.filter { props[$0] != nil })
    }
}
