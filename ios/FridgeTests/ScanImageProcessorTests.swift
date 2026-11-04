import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Fridge

/// F1.1: photos are shrunk to ≤ 1568 px and ≤ 500 KB, with all metadata (incl. GPS) removed.
final class ScanImageProcessorTests: XCTestCase {
    /// A noisy image (hard to compress) of the given size.
    private func noisyImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var seed: UInt32 = 12345
        for i in 0..<(width * height * 4) {
            seed = seed &* 1_103_515_245 &+ 12345
            buf[i] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        return ctx.makeImage()!
    }

    /// A smooth gradient: compresses like a real photo.
    private func smoothImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [UIColor.systemTeal.cgColor, UIColor.systemOrange.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return ctx.makeImage()!
    }

    /// A camera-like JPEG with EXIF, TIFF and GPS metadata.
    private func jpegWithGPS(width: Int, height: Int) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test lens"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test phone"],
        ]
        CGImageDestinationAddImage(dest, smoothImage(width: width, height: height), props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testFixtureReallyHasMetadata() {
        let keys = ScanImageProcessor.metadataKeys(jpegWithGPS(width: 400, height: 300))
        XCTAssertTrue(keys.contains(kCGImagePropertyGPSDictionary as String), "the test photo must carry GPS")
    }

    func testStripsAllMetadataIncludingGPS() throws {
        let photo = try ScanImageProcessor.process(jpegWithGPS(width: 2000, height: 1500))
        XCTAssertEqual(ScanImageProcessor.metadataKeys(photo.jpeg), [], "no EXIF, GPS, TIFF or IPTC left")
        let text = String(decoding: photo.jpeg, as: UTF8.self)
        XCTAssertFalse(text.contains("Test phone") || text.contains("Test lens"))
    }

    func testResizesLongestEdgeTo1568() throws {
        let landscape = try ScanImageProcessor.process(jpegWithGPS(width: 4032, height: 3024))
        XCTAssertEqual(max(landscape.width, landscape.height), 1568)
        XCTAssertEqual(landscape.height, 1176, "aspect ratio kept")
        let portrait = try ScanImageProcessor.process(UIImage(cgImage: smoothImage(width: 3024, height: 4032)))
        XCTAssertEqual(portrait.height, 1568)
    }

    func testNoExifSegmentInTheBytes() throws {
        // The same check the server makes: no APP1 "Exif" segment anywhere in the header.
        let photo = try ScanImageProcessor.process(jpegWithGPS(width: 2000, height: 1500))
        let bytes = [UInt8](photo.jpeg)
        let exifTag: [UInt8] = [0xFF, 0xE1]
        let headerEnd = (0..<(bytes.count - 1)).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA } ?? bytes.count
        let hasApp1 = (0..<(headerEnd - 1)).contains { bytes[$0] == exifTag[0] && bytes[$0 + 1] == exifTag[1] }
        XCTAssertFalse(hasApp1)
        XCTAssertNotNil(UIImage(data: photo.jpeg), "still a valid image after stripping")
    }

    func testNeverUpscales() throws {
        let small = try ScanImageProcessor.process(UIImage(cgImage: smoothImage(width: 800, height: 600)))
        XCTAssertEqual([small.width, small.height], [800, 600])
    }

    func testStaysUnder500KBEvenForNoisyPhotos() throws {
        // Random noise is the worst case for JPEG; real photos compress far better.
        let photo = try ScanImageProcessor.process(UIImage(cgImage: noisyImage(width: 4032, height: 3024)))
        XCTAssertLessThanOrEqual(photo.jpeg.count, ScanImageProcessor.targetBytes)
        XCTAssertLessThanOrEqual(max(photo.width, photo.height), 1568)
    }

    func testCameraOrientationIsBakedIn() throws {
        // A sensor image stored sideways with an "up is right" flag must come out upright.
        let sideways = UIImage(cgImage: noisyImage(width: 400, height: 300), scale: 1, orientation: .right)
        let photo = try ScanImageProcessor.process(sideways)
        XCTAssertEqual([photo.width, photo.height], [300, 400])
    }

    func testOutputIsJPEG() throws {
        let photo = try ScanImageProcessor.process(UIImage(cgImage: noisyImage(width: 100, height: 100)))
        XCTAssertEqual(Array(photo.jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertNotNil(UIImage(data: photo.jpeg))
    }

    func testRejectsNonImages() {
        XCTAssertThrowsError(try ScanImageProcessor.process(Data("not an image".utf8)))
    }

    func testServerErrorMapping() {
        func body(_ code: String) -> Data { Data(#"{"error":{"code":"\#(code)","message":"x"}}"#.utf8) }
        XCTAssertEqual(ScanAPI.map(code: 503, data: body("ai_disabled")), .aiDisabled)
        XCTAssertEqual(ScanAPI.map(code: 502, data: body("ai_failed")), .failed("ai_failed"))
        XCTAssertEqual(ScanAPI.map(code: 504, data: Data()), .failed("http 504"))
    }

    func testDecodesScanResponse() throws {
        let json = #"""
        {"location":"fridge","items":[{"temp_id":"t1","name":"eggs","ingredient_id":38,"display_name":"egg",
          "category":"dairy","match":"alias","quantity":6,"unit":"each","confidence":0.92,"low_confidence":false,
          "suggest_staple":false,"photo_indexes":[0,1]},
          {"temp_id":"t2","name":"dragon fruit","ingredient_id":null,"display_name":"dragon fruit","category":null,
          "match":"none","quantity":null,"unit":null,"confidence":0.55,"low_confidence":true,
          "suggest_staple":false,"photo_indexes":[1]}]}
        """#
        let r = try JSONDecoder().decode(ScanAPI.Response.self, from: Data(json.utf8))
        XCTAssertEqual(r.items.count, 2)
        XCTAssertEqual(r.items[0].ingredient_id, 38)
        XCTAssertNil(r.items[1].quantity, "\"some\"")
        XCTAssertTrue(r.items[1].low_confidence)
    }

    func testPlacementsIncludeStaples() {
        XCTAssertEqual(Placement.allCases.map(\.rawValue), ["fridge", "freezer", "pantry", "staples"],
                       "the server accepts exactly these locations")
    }
}
