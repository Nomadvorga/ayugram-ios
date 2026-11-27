import Foundation
import ImageIO
import XCTest
@testable import AyuPluginBridge

/// The image service on its own: handles, quotas, bounds, formats and cleanup.
final class AyuBridgeImageServiceTests: XCTestCase {
    private let owner = "image_tests"

    private func call(_ service: AyuBridgeImageService, _ operation: String, _ arguments: [String: AyuBridgeValue], owner: String? = nil) throws -> AyuBridgeValue {
        try service.perform(owner: owner ?? self.owner, operation: "image." + operation, arguments: arguments)
    }

    private func create(_ service: AyuBridgeImageService, _ mode: String, _ width: Int, _ height: Int, color: [Int64]? = nil, owner: String? = nil) throws -> String {
        var arguments: [String: AyuBridgeValue] = ["mode": .string(mode), "width": .integer(Int64(width)), "height": .integer(Int64(height))]
        if let color { arguments["color"] = .array(color.map(AyuBridgeValue.integer)) }
        let info = try self.call(service, "create", arguments, owner: owner)
        XCTAssertEqual(info["mode"], .string(mode))
        XCTAssertEqual(info["width"], .integer(Int64(width)))
        XCTAssertEqual(info["height"], .integer(Int64(height)))
        return try XCTUnwrap(info["image"].string)
    }

    private func pixels(_ service: AyuBridgeImageService, _ image: String, _ box: [Int64]) throws -> [UInt8] {
        let result = try self.call(service, "pixels.get", ["image": .string(image), "box": .array(box.map(AyuBridgeValue.integer))])
        return [UInt8](try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result["data"].string))))
    }

    private func assertFailure(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? AyuBridgeFailure)?.code, code, "\(error)", file: file, line: line)
        }
    }

    private func temporary(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ayu-image-tests-" + UUID().uuidString + "-" + name).path
    }

    func testCreateReadsBackItsColorInEveryMode() throws {
        let service = AyuBridgeImageService()
        for (mode, color) in [("L", [7]), ("LA", [7, 200]), ("RGB", [1, 2, 3]), ("RGBA", [1, 2, 3, 4])] as [(String, [Int64])] {
            let image = try self.create(service, mode, 5, 3, color: color)
            XCTAssertEqual(try self.pixels(service, image, [4, 2, 5, 3]), color.map { UInt8($0) }, mode)
            XCTAssertEqual(try self.pixels(service, image, [0, 0, 5, 3]).count, 15 * color.count)
        }
        let blank = try self.create(service, "RGBA", 2, 2)
        XCTAssertEqual(try self.pixels(service, blank, [0, 0, 2, 2]), [UInt8](repeating: 0, count: 16), "A new image is transparent black")
        XCTAssertEqual(service.usage(owner: self.owner), .init(images: 5, bytes: 15 + 30 + 45 + 60 + 16, fonts: 0))
    }

    func testUnknownModesOperationsAndArgumentsAreRefused() throws {
        let service = AyuBridgeImageService()
        let image = try self.create(service, "RGB", 4, 4)
        for mode in ["P", "1", "CMYK", "I;16", "RGBa", "HSV", ""] {
            self.assertFailure("UNSUPPORTED_API") { _ = try self.create(service, mode, 2, 2) }
            self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "convert", ["image": .string(image), "mode": .string(mode)]) }
        }
        self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "quantize", ["image": .string(image)]) }
        self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "resize", ["image": .string(image), "width": .integer(2), "height": .integer(2), "filter": .string("area")]) }
        self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "transform", ["image": .string(image), "width": .integer(2), "height": .integer(2), "matrix": .array([1, 0, 0, 0, 1, 0].map { .number($0) }), "filter": .string("lanczos")]) }
        self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "filter", ["image": .string(image), "kind": .string("oil")]) }
        self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "stats", ["image": .string(image), "kind": .string("entropy")]) }
        self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "draw", ["image": .string(image), "commands": .array([.object(["op": .string("polygon")])])]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "create", ["mode": .string("RGB"), "width": .integer(2), "height": .integer(2), "extra": .bool(true)]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "create", ["mode": .string("RGB"), "width": .integer(0), "height": .integer(2)]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "create", ["mode": .string("RGB"), "width": .integer(2), "height": .integer(2), "color": .array([.integer(1)])]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "create", ["mode": .string("L"), "width": .integer(2), "height": .integer(2), "color": .array([.integer(256)])]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "band", ["image": .string(image), "band": .integer(3)]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "point", ["image": .string(image), "table": .array([.integer(1)])]) }
        self.assertFailure("INVALID_HANDLE") { _ = try self.call(service, "copy", ["image": .string("nope")]) }
    }

    func testImagesBelongToOneOwnerAndAreFreedWithIt() throws {
        let service = AyuBridgeImageService()
        let mine = try self.create(service, "RGB", 8, 8)
        let other = try self.create(service, "RGB", 8, 8, owner: "someone_else")
        self.assertFailure("INVALID_HANDLE") { _ = try self.call(service, "copy", ["image": .string(other)]) }
        self.assertFailure("INVALID_HANDLE") { _ = try self.call(service, "paste", ["image": .string(mine), "source": .string(other), "box": .array([.integer(0), .integer(0)])]) }
        self.assertFailure("INVALID_HANDLE") { _ = try self.call(service, "release", ["images": .array([.string(mine)])], owner: "someone_else"); _ = try self.call(service, "copy", ["image": .string(mine)], owner: "someone_else") }
        XCTAssertEqual(service.usage(owner: self.owner).images, 1, "Another owner cannot release it")

        _ = try self.call(service, "release", ["images": .array([.string(mine), .string("unknown")])])
        XCTAssertEqual(service.usage(owner: self.owner), .init(images: 0, bytes: 0, fonts: 0))
        self.assertFailure("INVALID_HANDLE") { _ = try self.pixels(service, mine, [0, 0, 1, 1]) }

        _ = try self.create(service, "RGBA", 16, 16)
        _ = try self.call(service, "font.load", ["size": .number(12)])
        XCTAssertEqual(service.usage(owner: self.owner), .init(images: 1, bytes: 1024, fonts: 1))
        service.removeAll(owner: self.owner)
        XCTAssertEqual(service.usage(owner: self.owner), .init(images: 0, bytes: 0, fonts: 0))
        XCTAssertEqual(service.usage(owner: "someone_else").images, 1, "Cleanup is per owner")
    }

    func testQuotasBoundCountBytesPixelsAndFonts() throws {
        var limits = AyuBridgeImageLimits()
        limits.imagesPerPlugin = 3
        limits.bytesPerPlugin = 1_000
        limits.pixelsPerImage = 400
        limits.sidePixels = 64
        limits.fontsPerPlugin = 2
        limits.transferBytes = 64
        let service = AyuBridgeImageService(limits: limits)
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.create(service, "L", 65, 1) }
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.create(service, "L", 21, 20) }
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.create(service, "RGBA", 20, 20) }
        let first = try self.create(service, "RGB", 10, 10)
        let second = try self.create(service, "RGB", 10, 10)
        _ = try self.create(service, "RGB", 10, 10)
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.create(service, "L", 1, 1) }
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.call(service, "copy", ["image": .string(first)]) }
        _ = try self.call(service, "release", ["images": .array([.string(second)])])
        // 600 bytes are held; a 4-band copy of a 10x10 image would need 400 more than the 400 left... exactly fits.
        _ = try self.call(service, "convert", ["image": .string(first), "mode": .string("RGBA")])
        XCTAssertEqual(service.usage(owner: self.owner), .init(images: 3, bytes: 1_000, fonts: 0))
        // An in-place change that grows an image is charged too.
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.call(service, "putalpha", ["image": .string(first), "alpha": .integer(9)]) }
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.call(service, "resize", ["image": .string(first), "width": .integer(30), "height": .integer(30), "filter": .string("nearest")]) }
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.pixels(service, first, [0, 0, 10, 10]) }
        XCTAssertEqual(try self.pixels(service, first, [0, 0, 7, 3]).count, 63)

        _ = try self.call(service, "font.load", ["size": .number(12)])
        _ = try self.call(service, "font.load", ["size": .number(13)])
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.call(service, "font.load", ["size": .number(14)]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "font.load", ["size": .number(0)]) }
    }

    func testPixelTransferIsBoundedAndChecked() throws {
        let service = AyuBridgeImageService()
        let image = try self.create(service, "RGB", 4, 3)
        let patch = Data([10, 20, 30, 40, 50, 60]).base64EncodedString()
        _ = try self.call(service, "pixels.put", ["image": .string(image), "box": .array([1, 2, 3, 3].map { .integer($0) }), "data": .string(patch)])
        XCTAssertEqual(try self.pixels(service, image, [0, 2, 4, 3]), [0, 0, 0, 10, 20, 30, 40, 50, 60, 0, 0, 0])
        for box in [[0, 0, 5, 1], [-1, 0, 2, 1], [2, 0, 2, 1], [0, 3, 1, 4]] as [[Int64]] {
            self.assertFailure("INVALID_ARGUMENTS") { _ = try self.pixels(service, image, box) }
        }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "pixels.put", ["image": .string(image), "box": .array([0, 0, 2, 1].map { .integer($0) }), "data": .string(patch + "AAAA")]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "pixels.put", ["image": .string(image), "box": .array([0, 0, 2, 1].map { .integer($0) }), "data": .string("not base64!")]) }
        let large = try self.create(service, "RGBA", 512, 512)
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.pixels(service, large, [0, 0, 512, 65]) }
        XCTAssertEqual(try self.pixels(service, large, [0, 0, 512, 64]).count, 131_072)
    }

    func testPNGKeepsStraightAlphaAndEveryModeExactly() throws {
        let service = AyuBridgeImageService()
        let samples: [(String, [UInt8])] = [
            ("L", [0, 1, 127, 255]), ("LA", [200, 0, 200, 1, 9, 128, 255, 255]), ("RGB", [255, 0, 0, 0, 255, 0, 0, 0, 255, 17, 34, 51]),
            // Low alpha with bright color: premultiplied storage would lose these values.
            ("RGBA", [255, 128, 7, 1, 250, 250, 250, 2, 13, 200, 99, 0, 1, 2, 3, 255]),
        ]
        for (mode, bytes) in samples {
            let image = try self.create(service, mode, 2, 2)
            _ = try self.call(service, "pixels.put", ["image": .string(image), "box": .array([0, 0, 2, 2].map { .integer($0) }), "data": .string(Data(bytes).base64EncodedString())])
            let path = self.temporary(mode + ".png")
            defer { try? FileManager.default.removeItem(atPath: path) }
            let written = try self.call(service, "encode", ["image": .string(image), "format": .string("PNG"), "path": .string(path)])
            let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
            XCTAssertEqual(written["bytes"], .integer(Int64(data.count)))
            XCTAssertEqual([UInt8](data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            // The color type in the IHDR chunk: 0 gray, 4 gray+alpha, 2 RGB, 6 RGBA.
            XCTAssertEqual(data[25], ["L": 0, "LA": 4, "RGB": 2, "RGBA": 6][mode], mode)
            XCTAssertEqual(data[24], 8, "bit depth")
            for arguments in [["path": AyuBridgeValue.string(path)], ["data": .string(data.base64EncodedString())]] {
                let decoded = try self.call(service, "decode", arguments)
                XCTAssertEqual(decoded["mode"], .string(mode))
                XCTAssertEqual(decoded["format"], .string("PNG"))
                XCTAssertEqual(decoded["width"], .integer(2))
                XCTAssertEqual(decoded["frames"], .integer(1))
                XCTAssertEqual(decoded["orientation"], .integer(1))
                var expected = bytes
                // A fully transparent pixel has no color to keep.
                if mode == "RGBA" { expected.replaceSubrange(8..<11, with: try self.pixels(service, try XCTUnwrap(decoded["image"].string), [0, 1, 1, 2]).prefix(3)) }
                if mode == "LA" { expected[0] = try self.pixels(service, try XCTUnwrap(decoded["image"].string), [0, 0, 1, 1])[0] }
                XCTAssertEqual(try self.pixels(service, try XCTUnwrap(decoded["image"].string), [0, 0, 2, 2]), expected, mode)
            }
        }
    }

    func testJPEGWritesAndReadsWithoutAlphaAndRefusesIt() throws {
        let service = AyuBridgeImageService()
        let image = try self.create(service, "RGB", 32, 24, color: [200, 100, 50])
        let path = self.temporary("photo.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var sizes: [Int64] = []
        for quality in [10, 95] as [Int64] {
            let written = try self.call(service, "encode", ["image": .string(image), "format": .string("JPEG"), "path": .string(path), "quality": .integer(quality)])
            sizes.append(try XCTUnwrap(written["bytes"].integer))
            let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
            XCTAssertEqual([UInt8](data.prefix(3)), [0xFF, 0xD8, 0xFF])
            let decoded = try self.call(service, "decode", ["path": .string(path)])
            XCTAssertEqual(decoded["mode"], .string("RGB"))
            XCTAssertEqual(decoded["format"], .string("JPEG"))
            XCTAssertEqual([decoded["width"], decoded["height"]], [.integer(32), .integer(24)])
            let pixel = try self.pixels(service, try XCTUnwrap(decoded["image"].string), [16, 12, 17, 13])
            for (value, expected) in zip(pixel, [200, 100, 50]) { XCTAssertLessThanOrEqual(abs(Int(value) - expected), 6) }
        }
        XCTAssertLessThanOrEqual(sizes[0], sizes[1], "quality reaches the encoder")
        let gray = try self.create(service, "L", 16, 16, color: [90])
        _ = try self.call(service, "encode", ["image": .string(gray), "format": .string("JPEG"), "path": .string(path)])
        XCTAssertEqual(try self.call(service, "decode", ["path": .string(path)])["mode"], .string("L"))

        let alpha = try self.create(service, "RGBA", 4, 4)
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "encode", ["image": .string(alpha), "format": .string("JPEG"), "path": .string(path)]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "encode", ["image": .string(image), "format": .string("JPEG"), "path": .string(path), "quality": .integer(101)]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "encode", ["image": .string(image), "format": .string("PNG"), "path": .string("relative.png")]) }
        self.assertFailure("IO_ERROR") { _ = try self.call(service, "encode", ["image": .string(image), "format": .string("PNG"), "path": .string("/nonexistent-directory-for-tests/out.png")]) }
        for format in ["GIF", "BMP", "TIFF", "PDF", "png", ""] {
            self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "encode", ["image": .string(image), "format": .string(format), "path": .string(path)]) }
        }
    }

    func testWebPIsWrittenOnlyWhereTheSystemEncodesIt() throws {
        let service = AyuBridgeImageService()
        let image = try self.create(service, "RGB", 8, 8, color: [1, 2, 3])
        let path = self.temporary("picture.webp")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let system = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("org.webmproject.webp")
        XCTAssertEqual(AyuBridgeImageCodec.canEncode("WEBP"), system)
        if system {
            _ = try self.call(service, "encode", ["image": .string(image), "format": .string("WEBP"), "path": .string(path)])
            XCTAssertEqual(try self.call(service, "decode", ["path": .string(path)])["format"], .string("WEBP"))
        } else {
            XCTAssertThrowsError(try self.call(service, "encode", ["image": .string(image), "format": .string("WEBP"), "path": .string(path)])) { error in
                XCTAssertEqual((error as? AyuBridgeFailure)?.code, "UNSUPPORTED_API")
                XCTAssertEqual((error as? AyuBridgeFailure)?.message.contains("WEBP"), true, "The refusal names the format")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Nothing is written under another format's name")
        }
    }

    func testDecodeRejectsWhatItCannotIdentifyAndWhatIsTooLarge() throws {
        var limits = AyuBridgeImageLimits()
        limits.pixelsPerImage = 100
        limits.fileBytes = 4_096
        let small = AyuBridgeImageService(limits: limits)
        let service = AyuBridgeImageService()
        let image = try self.create(service, "RGB", 20, 20)
        let path = self.temporary("big.png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try self.call(service, "encode", ["image": .string(image), "format": .string("PNG"), "path": .string(path)])
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.call(small, "decode", ["path": .string(path)]) }
        XCTAssertEqual(small.usage(owner: self.owner).images, 0, "A refused decode leaves nothing behind")

        let garbage = self.temporary("garbage.png")
        defer { try? FileManager.default.removeItem(atPath: garbage) }
        try Data(repeating: 0x41, count: 512).write(to: URL(fileURLWithPath: garbage))
        self.assertFailure("IMAGE_FORMAT") { _ = try self.call(service, "decode", ["path": .string(garbage)]) }
        self.assertFailure("IMAGE_FORMAT") { _ = try self.call(service, "decode", ["data": .string(Data("<svg/>".utf8).base64EncodedString())]) }
        self.assertFailure("IO_ERROR") { _ = try self.call(service, "decode", ["path": .string(self.temporary("absent.png"))]) }
        self.assertFailure("IO_ERROR") { _ = try self.call(service, "decode", ["path": .string(FileManager.default.temporaryDirectory.path)]) }
        try Data(repeating: 0, count: 5_000).write(to: URL(fileURLWithPath: garbage))
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.call(small, "decode", ["path": .string(garbage)]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "decode", ["path": .string("relative.png")]) }
        self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "decode", ["path": .string(path), "data": .string("AAAA")]) }
    }

    func testShapesCoverExactPixelsAndMixInkByMode() throws {
        let service = AyuBridgeImageService()
        func draw(_ image: String, _ commands: [[String: AyuBridgeValue]]) throws {
            _ = try self.call(service, "draw", ["image": .string(image), "commands": .array(commands.map(AyuBridgeValue.object))])
        }
        func numbers(_ values: [Double]) -> AyuBridgeValue { .array(values.map(AyuBridgeValue.number)) }
        func ink(_ values: [Int64]) -> AyuBridgeValue { .array(values.map(AyuBridgeValue.integer)) }

        let gray = try self.create(service, "L", 8, 6)
        try draw(gray, [["op": .string("rect"), "box": numbers([2, 1, 5, 4]), "fill": ink([255])]])
        XCTAssertEqual(try self.pixels(service, gray, [0, 0, 8, 6]), [
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 255, 255, 255, 0, 0, 0,
            0, 0, 255, 255, 255, 0, 0, 0,
            0, 0, 255, 255, 255, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
        ], "A rectangle covers the pixels between its edges and nothing else")
        try draw(gray, [["op": .string("rect"), "box": numbers([0, 0, 8, 6]), "fill": ink([9]), "ring": .integer(1)]])
        XCTAssertEqual(try self.pixels(service, gray, [0, 0, 8, 2]), [9, 9, 9, 9, 9, 9, 9, 9, 9, 0, 255, 255, 255, 0, 0, 9])

        // A one-pixel line through pixel centers, reaching half a pixel past both, inks one pixel per column, ends included.
        let line = try self.create(service, "L", 12, 8)
        let reach = 0.5 / (9.0 * 9.0 + 4.0 * 4.0).squareRoot()
        try draw(line, [["op": .string("line"), "points": numbers([1.5 - 9 * reach, 1.5 - 4 * reach, 10.5 + 9 * reach, 5.5 + 4 * reach]), "stroke": ink([255]), "width": .integer(1)]])
        let rows = try self.pixels(service, line, [0, 0, 12, 8])
        XCTAssertEqual(rows[1 * 12 + 1], 255, "first end")
        XCTAssertEqual(rows[5 * 12 + 10], 255, "last end")
        for column in 1...10 { XCTAssertEqual((0..<8).filter { rows[$0 * 12 + column] != 0 }.count, 1, "column \(column)") }

        // Replace: every band moves to the ink, alpha included. Over: source-over with the ink's alpha.
        let replace = try self.create(service, "RGBA", 2, 1, color: [10, 20, 30, 40])
        try draw(replace, [["op": .string("rect"), "box": numbers([0, 0, 1, 1]), "fill": ink([200, 100, 50, 0])]])
        XCTAssertEqual(try self.pixels(service, replace, [0, 0, 2, 1]), [200, 100, 50, 0, 10, 20, 30, 40])
        let over = try self.create(service, "RGBA", 3, 1, color: [0, 0, 255, 255])
        try draw(over, [["op": .string("rect"), "box": numbers([0, 0, 1, 1]), "fill": ink([255, 0, 0, 128]), "blend": .string("over")],
                        ["op": .string("rect"), "box": numbers([1, 0, 2, 1]), "fill": ink([255, 0, 0, 0]), "blend": .string("over")]])
        XCTAssertEqual(try self.pixels(service, over, [0, 0, 3, 1]), [128, 0, 127, 255, 0, 0, 255, 255, 0, 0, 255, 255])
        let clear = try self.create(service, "RGBA", 1, 1)
        try draw(clear, [["op": .string("fill"), "fill": ink([255, 0, 0, 128]), "blend": .string("over")]])
        XCTAssertEqual(try self.pixels(service, clear, [0, 0, 1, 1]), [255, 0, 0, 128], "Over transparent pixels the ink keeps its own color")
        let opaque = try self.create(service, "RGB", 1, 1, color: [10, 20, 30])
        try draw(opaque, [["op": .string("fill"), "fill": ink([200, 100, 50, 128]), "blend": .string("over")]])
        XCTAssertEqual(try self.pixels(service, opaque, [0, 0, 1, 1]), [105, 60, 40])

        // Anti-aliasing: half a pixel of coverage is half of the ink.
        let smooth = try self.create(service, "L", 3, 1)
        try draw(smooth, [["op": .string("rect"), "box": numbers([0.5, 0, 2, 1]), "fill": ink([200]), "antialias": .bool(true)]])
        let edge = try self.pixels(service, smooth, [0, 0, 3, 1])
        XCTAssertEqual(edge[1], 200)
        XCTAssertEqual(edge[2], 0)
        XCTAssertLessThanOrEqual(abs(Int(edge[0]) - 100), 2)

        // A failing command changes nothing, also when earlier commands in the list were fine.
        self.assertFailure("INVALID_ARGUMENTS") {
            try draw(gray, [["op": .string("fill"), "fill": ink([77])], ["op": .string("rect"), "box": numbers([3, 0, 1, 1]), "fill": ink([1])]])
        }
        XCTAssertEqual(try self.pixels(service, gray, [3, 2, 4, 3]), [255])
        self.assertFailure("INVALID_ARGUMENTS") { try draw(gray, [["op": .string("rect"), "box": numbers([0, 0, 1, 1]), "fill": ink([1, 2, 3])]]) }
        self.assertFailure("RESOURCE_LIMIT") { try draw(gray, [[String: AyuBridgeValue]](repeating: ["op": .string("fill"), "fill": ink([1])], count: 257)) }
    }

    func testDrawingAnotherImageScalesClipsAndBlends() throws {
        let service = AyuBridgeImageService()
        let source = try self.create(service, "RGBA", 2, 2)
        let texels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128]
        _ = try self.call(service, "pixels.put", ["image": .string(source), "box": .array([0, 0, 2, 2].map { .integer($0) }), "data": .string(Data(texels).base64EncodedString())])
        func numbers(_ values: [Double]) -> AyuBridgeValue { .array(values.map(AyuBridgeValue.number)) }

        // Unscaled at an integer position: the opaque texels arrive unchanged, the half-transparent one is blended.
        let target = try self.create(service, "RGBA", 4, 4, color: [0, 0, 0, 255])
        _ = try self.call(service, "draw", ["image": .string(target), "commands": .array([.object(["op": .string("image"), "source": .string(source), "dst": numbers([1, 1, 3, 3])])])])
        XCTAssertEqual(try self.pixels(service, target, [1, 1, 3, 2]), [255, 0, 0, 255, 0, 255, 0, 255])
        let blended = try self.pixels(service, target, [2, 2, 3, 3])
        XCTAssertEqual(blended[3], 255)
        for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(blended[channel]) - 128), 1) }
        XCTAssertEqual(try self.pixels(service, target, [0, 0, 1, 1]), [0, 0, 0, 255], "Nothing outside the destination changes")

        // Doubled without filtering: each texel becomes a 2x2 block. A clip keeps the left half only.
        let scaled = try self.create(service, "RGB", 4, 4)
        _ = try self.call(service, "draw", ["image": .string(scaled), "commands": .array([.object([
            "op": .string("image"), "source": .string(source), "src": .array([0, 0, 2, 1].map { .integer($0) }), "dst": numbers([0, 0, 4, 2]),
            "clips": .array([.object(["matrix": numbers([1, 0, 0, 1, 0, 0]), "rect": numbers([0, 0, 3, 4])])]),
        ])])])
        XCTAssertEqual(try self.pixels(service, scaled, [0, 0, 4, 2]), [255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 0])
        XCTAssertEqual(try self.pixels(service, scaled, [0, 2, 4, 3]), [UInt8](repeating: 0, count: 12))

        // A matrix moves and scales the destination.
        let moved = try self.create(service, "RGB", 6, 6)
        _ = try self.call(service, "draw", ["image": .string(moved), "commands": .array([.object([
            "op": .string("image"), "source": .string(source), "src": .array([0, 0, 1, 1].map { .integer($0) }), "dst": numbers([0, 0, 1, 1]), "matrix": numbers([2, 0, 0, 2, 3, 1]),
        ])])])
        XCTAssertEqual(try self.pixels(service, moved, [2, 1, 6, 2]), [0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 0, 0])
        self.assertFailure("INVALID_ARGUMENTS") {
            _ = try self.call(service, "draw", ["image": .string(moved), "commands": .array([.object(["op": .string("image"), "source": .string(source), "src": .array([0, 0, 3, 1].map { .integer($0) }), "dst": numbers([0, 0, 1, 1])])])])
        }
    }

    func testPaintAndPathReferencesAreResolvedByTheCaller() throws {
        let service = AyuBridgeImageService()
        let image = try self.create(service, "RGBA", 6, 6)
        let paint: AyuBridgeValue = .object(["$handle": .string("paint-1"), "$class": .string("android.graphics.Paint")])
        let path: AyuBridgeValue = .object(["$handle": .string("path-1"), "$class": .string("android.graphics.Path")])
        let commands: AyuBridgeValue = .array([.object(["op": .string("path"), "path": path, "paint": paint])])
        // Without a resolver a reference is not accepted as data.
        self.assertFailure("UNSUPPORTED_API") { _ = try self.call(service, "draw", ["image": .string(image), "commands": commands]) }
        let resolver: AyuBridgeImageService.Resolver = { reference in
            if reference["$handle"] == .string("paint-1") {
                return ("android.graphics.Paint", ["flags": .integer(0), "color": .integer(Int64(Int32(bitPattern: 0xFF10_2030))), "stroke_width": .number(0),
                                                 "text_size": .number(12), "style": .string("FILL"), "cap": .string("BUTT"), "join": .string("MITER"),
                                                 "anti_alias": .bool(false), "filter_bitmap": .bool(false), "dither": .bool(false)])
            }
            return ("android.graphics.Path", ["commands": .array([
                .object(["op": .string("move"), "x": .number(1), "y": .number(1)]), .object(["op": .string("line"), "x": .number(5), "y": .number(1)]),
                .object(["op": .string("line"), "x": .number(5), "y": .number(4)]), .object(["op": .string("line"), "x": .number(1), "y": .number(4)]), .object(["op": .string("close")]),
            ])])
        }
        _ = try service.perform(owner: self.owner, operation: "image.draw", arguments: ["image": .string(image), "commands": commands], resolve: resolver)
        XCTAssertEqual(try self.pixels(service, image, [0, 1, 2, 2]), [0, 0, 0, 0, 0x10, 0x20, 0x30, 255])
        XCTAssertEqual(try self.pixels(service, image, [4, 3, 6, 4]), [0x10, 0x20, 0x30, 255, 0, 0, 0, 0])
        XCTAssertEqual(try self.pixels(service, image, [1, 4, 2, 5]), [0, 0, 0, 0])
        let swapped: AyuBridgeValue = .array([.object(["op": .string("fill"), "paint": path])])
        XCTAssertThrowsError(try service.perform(owner: self.owner, operation: "image.draw", arguments: ["image": .string(image), "commands": swapped], resolve: resolver))
    }

    func testFontsLoadFromFilesMeasureAndDrawText() throws {
        let service = AyuBridgeImageService()
        let system = try self.call(service, "font.load", ["size": .number(20)])
        let systemID = try XCTUnwrap(system["font"].string)
        XCTAssertGreaterThan(try XCTUnwrap(system["ascent"].number), 10)
        XCTAssertGreaterThan(try XCTUnwrap(system["descent"].number), 1)
        let measured = try self.call(service, "font.measure", ["font": .string(systemID), "text": .string("Hello")])
        let advance = try XCTUnwrap(measured["advance"].number)
        let ink = try XCTUnwrap(measured["ink"].array).compactMap(\.number)
        XCTAssertGreaterThan(advance, 30)
        XCTAssertLessThan(advance, 70)
        XCTAssertEqual(ink.count, 4)
        XCTAssertLessThan(ink[1], 0, "Ink rises above the baseline")
        XCTAssertLessThanOrEqual(abs(ink[3]), 1, "These letters sit on the baseline")
        let wider = try self.call(service, "font.measure", ["font": .string(systemID), "text": .string("Hello"), "stroke_width": .number(3)])
        XCTAssertEqual(try XCTUnwrap(wider["ink"].array?[2].number), ink[2] + 3, accuracy: 0.001)
        XCTAssertEqual(try self.call(service, "font.measure", ["font": .string(systemID), "text": .string("")])["ink"], .array([.number(0), .number(0), .number(0), .number(0)]))

        let image = try self.create(service, "L", 120, 40)
        _ = try self.call(service, "draw", ["image": .string(image), "commands": .array([.object([
            "op": .string("text"), "text": .string("Hello"), "font": .string(systemID), "origin": .array([.number(10), .number(30)]), "fill": .array([.integer(255)]),
        ])])])
        let box = try XCTUnwrap(try self.call(service, "stats", ["image": .string(image), "kind": .string("bbox")]).array).compactMap(\.integer)
        XCTAssertLessThanOrEqual(abs(Double(box[0]) - (10 + ink[0])), 1.5, "left edge of the ink")
        XCTAssertLessThanOrEqual(abs(Double(box[1]) - (30 + ink[1])), 1.5, "top edge of the ink")
        XCTAssertLessThanOrEqual(abs(Double(box[2]) - (10 + ink[2])), 1.5, "right edge of the ink")
        XCTAssertLessThanOrEqual(abs(Double(box[3]) - (30 + ink[3])), 1.5, "bottom edge of the ink")

        let file = "/System/Library/Fonts/Supplemental/Arial.ttf"
        if FileManager.default.fileExists(atPath: file) {
            let loaded = try self.call(service, "font.load", ["path": .string(file), "size": .number(40)])
            XCTAssertEqual(loaded["family"], .string("Arial"))
            XCTAssertEqual(try XCTUnwrap(loaded["ascent"].number), 36.2, accuracy: 0.2)
            self.assertFailure("INVALID_ARGUMENTS") { _ = try self.call(service, "font.load", ["path": .string(file), "size": .number(40), "index": .integer(9)]) }
        }
        let notAFont = self.temporary("font.ttf")
        defer { try? FileManager.default.removeItem(atPath: notAFont) }
        try Data(repeating: 7, count: 2_000).write(to: URL(fileURLWithPath: notAFont))
        self.assertFailure("IMAGE_FORMAT") { _ = try self.call(service, "font.load", ["path": .string(notAFont), "size": .number(20)]) }
        self.assertFailure("IO_ERROR") { _ = try self.call(service, "font.load", ["path": .string(self.temporary("absent.ttf")), "size": .number(20)]) }
        self.assertFailure("INVALID_HANDLE") { _ = try self.call(service, "font.measure", ["font": .string("nope"), "text": .string("x")]) }
        self.assertFailure("RESOURCE_LIMIT") { _ = try self.call(service, "font.measure", ["font": .string(systemID), "text": .string(String(repeating: "x", count: 20_000))]) }
        _ = try self.call(service, "release", ["fonts": .array([.string(systemID)])])
        self.assertFailure("INVALID_HANDLE") { _ = try self.call(service, "font.measure", ["font": .string(systemID), "text": .string("x")]) }
    }

    func testSnapshotsForViewsAreBudgetedReplacedPerViewAndDroppedWithTheOwner() throws {
        let service = AyuBridgeImageService()
        let image = try self.create(service, "RGBA", 10, 10, color: [1, 2, 3, 4])
        let gray = try self.create(service, "L", 10, 10)
        self.assertFailure("RESOURCE_LIMIT") { _ = try service.snapshot(owner: self.owner, image: image, view: "view-1", budget: 399) }
        let first = try service.snapshot(owner: self.owner, image: image, view: "view-1", budget: 400)
        XCTAssertEqual(first.bytes, 400)
        XCTAssertEqual(try service.snapshot(owner: self.owner, image: gray, view: "view-2", budget: 100).bytes, 100)
        let second = try service.snapshot(owner: self.owner, image: image, view: "view-1", budget: 400)
        XCTAssertEqual(AyuBridgeImageSnapshots.shared.pending(owner: self.owner), 2, "A view keeps one pending image")
        XCTAssertNil(AyuBridgeImageSnapshots.shared.take(first.token), "The replaced snapshot is gone")
        // The snapshot is a copy: later changes to the image do not reach the view.
        _ = try self.call(service, "draw", ["image": .string(image), "commands": .array([.object(["op": .string("fill"), "fill": .array([9, 9, 9, 9].map { .integer($0) })])])])
        let taken = try XCTUnwrap(AyuBridgeImageSnapshots.shared.take(second.token))
        XCTAssertEqual([taken.width, taken.height, taken.bitsPerPixel], [10, 10, 32])
        XCTAssertEqual(taken.alphaInfo, .last, "Straight alpha reaches the view")
        XCTAssertEqual([UInt8](try XCTUnwrap(taken.dataProvider?.data as Data?).prefix(4)), [1, 2, 3, 4])
        XCTAssertNil(AyuBridgeImageSnapshots.shared.take(second.token), "A token is redeemed once")
        self.assertFailure("INVALID_HANDLE") { _ = try service.snapshot(owner: "someone_else", image: image, view: "view-1", budget: 1_000) }
        service.removeAll(owner: self.owner)
        XCTAssertEqual(AyuBridgeImageSnapshots.shared.pending(owner: self.owner), 0)
    }

    func testHostServesImageOperationsDeclaresThemAndFreesImagesOnDeactivate() throws {
        let host = AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuBridgeImageServiceTests." + UUID().uuidString)!, trustedOwner: { nil }, callback: { _, _, _ in })
        func dispatch(_ owner: String, _ operation: String, _ arguments: [String: AyuBridgeValue], plugin: String? = nil) throws -> AyuBridgeValue {
            let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(plugin ?? owner), "operation": .string(operation), "arguments": .object(arguments)])
            let request = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
            var answer = ""
            let done = expectation(description: operation)
            DispatchQueue.global().async { answer = host.dispatch(request, owner: owner); done.fulfill() }
            wait(for: [done], timeout: 10)
            let response = try JSONDecoder().decode(AyuBridgeValue.self, from: Data(answer.utf8))
            if let code = response["error"]["code"].string { throw AyuBridgeFailure(code, response["error"]["message"].string ?? "") }
            return response["result"]
        }
        let capabilities = try dispatch("inspector", "runtime.capabilities", [:], plugin: "$runtime")
        let declared = Set((capabilities["operations"].array ?? []).compactMap(\.string))
        XCTAssertTrue(Set(AyuBridgeImageService.operations).isSubset(of: declared))
        XCTAssertEqual(AyuBridgeImageService.operations.count, 25)
        let modules = Set((capabilities["modules"].array ?? []).compactMap(\.string))
        XCTAssertTrue(modules.isSuperset(of: ["PIL", "PIL.Image", "PIL.ImageDraw", "PIL.ImageFont", "PIL.ImageFilter", "PIL.ImageOps", "PIL.ImageEnhance", "PIL.ImageChops", "PIL.ImageColor"]))

        self.assertFailure("UNAUTHORIZED") { _ = try dispatch("images_host", "image.create", ["mode": .string("L"), "width": .integer(1), "height": .integer(1)]) }
        _ = try dispatch("images_host", "plugin.authorize", ["operations": .array([.string("image.create"), .string("image.draw")])])
        _ = try dispatch("images_host", "plugin.activate", ["generation": .string("g1")])
        let created = try dispatch("images_host", "image.create", ["mode": .string("RGBA"), "width": .integer(4), "height": .integer(4)])
        let image = try XCTUnwrap(created["image"].string)
        self.assertFailure("UNSUPPORTED_API") { _ = try dispatch("images_host", "image.nonexistent", [:]) }

        // A Paint of the Java facade, named by reference in a draw command.
        let paint = try dispatch("images_host", "java.construct", ["class_name": .string("android.graphics.Paint"), "args": .array([])])
        _ = try dispatch("images_host", "java.invoke", ["target": paint, "name": .string("setColor"), "args": .array([.integer(Int64(Int32(bitPattern: 0x80FF_0000)))])])
        _ = try dispatch("images_host", "image.draw", ["image": .string(image), "commands": .array([.object(["op": .string("rect"), "box": .array([0, 0, 2, 2].map { .integer($0) }), "paint": paint])])])
        let pixels = try dispatch("images_host", "image.pixels.get", ["image": .string(image), "box": .array([1, 1, 3, 2].map { .integer($0) })])
        XCTAssertEqual([UInt8](try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(pixels["data"].string)))), [255, 0, 0, 128, 0, 0, 0, 0])

        _ = try dispatch("images_host", "plugin.deactivate", ["generation": .string("g1")])
        _ = try dispatch("images_host", "plugin.authorize", [:])
        self.assertFailure("INVALID_HANDLE") { _ = try dispatch("images_host", "image.copy", ["image": .string(image)]) }
    }
}
