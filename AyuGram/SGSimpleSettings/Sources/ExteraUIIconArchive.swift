import Foundation

public enum ExteraUIIconError: Error, LocalizedError {
    case invalidArchive, limitExceeded, invalidMetadata, unsafePath, unsupportedImage, corruptFile, storage

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The file is not a supported ZIP icon pack."
        case .limitExceeded: return "The icon pack exceeds its file, size or complexity limit."
        case .invalidMetadata: return "The icon pack metadata is invalid."
        case .unsafePath: return "The icon pack contains an unsafe or conflicting file path."
        case .unsupportedImage: return "An icon uses an unsupported image or SVG feature."
        case .corruptFile: return "An icon pack file failed its integrity check."
        case .storage: return "The icon pack could not be saved."
        }
    }
}

/// Android .icons ZIP limits. No filesystem extraction takes place in this reader.
public enum ExteraUIIconArchive {
    public static let maxEntries = 3_000
    public static let maxFileBytes = 10 * 1024 * 1024
    public static let maxTotalBytes = 100 * 1024 * 1024
    public static let maxMetadataBytes = 256 * 1024
    public static let maxArchiveBytes = maxTotalBytes + 4 * 1024 * 1024

    public static func path(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ExteraUIIconError.unsafePath }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ExteraUIIconError.unsafePath }
        return name.precomposedStringWithCanonicalMapping
    }

    public static func readFile(_ url: URL, limit: Int = maxArchiveBytes) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw ExteraUIIconError.limitExceeded }
        }
        return data
    }

    public static func decode(_ input: Data) throws -> [String: Data] {
        let data = [UInt8](input)
        guard data.count >= 22, data.count <= maxArchiveBytes else { throw ExteraUIIconError.limitExceeded }
        func number(_ at: Int, _ width: Int) throws -> Int {
            guard at >= 0, width <= data.count, at <= data.count - width else { throw ExteraUIIconError.invalidArchive }
            return (0 ..< width).reduce(0) { $0 | (Int(data[at + $1]) << ($1 * 8)) }
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try number(offset, 4) == 0x06054b50, try offset + 22 + number(offset + 20, 2) == data.count { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0,
              try number(end + 8, 2) == number(end + 10, 2) else { throw ExteraUIIconError.invalidArchive }
        let count = try number(end + 10, 2)
        let directorySize = try number(end + 12, 4)
        let directory = try number(end + 16, 4)
        guard count > 0, count <= maxEntries, directory <= end, directorySize == end - directory else { throw ExteraUIIconError.invalidArchive }
        var position = directory
        var total = 0
        var files: [String: Data] = [:]
        var seen = Set<String>()
        var paths: [(String, Bool)] = []
        var regions: [Range<Int>] = []
        for _ in 0 ..< count {
            guard try number(position, 4) == 0x02014b50 else { throw ExteraUIIconError.invalidArchive }
            let flags = try number(position + 8, 2)
            let method = try number(position + 10, 2)
            let checksum = try number(position + 16, 4)
            let compressed = try number(position + 20, 4)
            let size = try number(position + 24, 4)
            let nameSize = try number(position + 28, 2)
            let extraSize = try number(position + 30, 2)
            let commentSize = try number(position + 32, 2)
            let attributes = try number(position + 38, 4)
            let local = try number(position + 42, 4)
            let next = position + 46 + nameSize + extraSize + commentSize
            guard next <= end, nameSize > 0, try number(position + 34, 2) == 0,
                  flags & ~0x080e == 0, method == 0 || method == 8,
                  compressed != 0xffffffff, size != 0xffffffff,
                  let rawName = String(bytes: data[(position + 46) ..< (position + 46 + nameSize)], encoding: .utf8) else { throw ExteraUIIconError.invalidArchive }
            let isDirectory = rawName.hasSuffix("/")
            let name = try path(isDirectory ? String(rawName.dropLast()) : rawName)
            // APFS can be case-insensitive; reject collisions before writing any bytes.
            let collision = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(collision).inserted else { throw ExteraUIIconError.unsafePath }
            let unixType = (attributes >> 16) & 0xf000
            guard unixType == 0 || unixType == 0x8000 || (unixType == 0x4000 && isDirectory) else { throw ExteraUIIconError.unsafePath }
            paths.append((collision, isDirectory))
            guard size <= maxFileBytes, size <= maxTotalBytes - total,
                  size == 0 || (compressed > 0 && Double(size) / Double(compressed) <= 250) else { throw ExteraUIIconError.limitExceeded }
            total += size
            guard local < directory, try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method else { throw ExteraUIIconError.invalidArchive }
            let localNameSize = try number(local + 26, 2)
            let localExtraSize = try number(local + 28, 2)
            let start = local + 30 + localNameSize + localExtraSize
            guard localNameSize == nameSize, start <= directory, compressed <= directory - start,
                  Array(data[(local + 30) ..< (local + 30 + localNameSize)]) == Array(data[(position + 46) ..< (position + 46 + nameSize)]) else { throw ExteraUIIconError.invalidArchive }
            if flags & 8 == 0 {
                guard try number(local + 14, 4) == checksum, try number(local + 18, 4) == compressed, try number(local + 22, 4) == size else { throw ExteraUIIconError.invalidArchive }
            }
            let region = local ..< (start + compressed)
            guard !regions.contains(where: { $0.overlaps(region) }) else { throw ExteraUIIconError.invalidArchive }
            regions.append(region)
            let bytes = Array(data[start ..< (start + compressed)])
            let result: [UInt8]
            if method == 0 {
                guard compressed == size else { throw ExteraUIIconError.corruptFile }
                result = bytes
            } else {
                result = try ExteraUIIconDeflate.decode(bytes, size: size)
            }
            guard result.count == size, crc32(Data(result)) == UInt32(checksum) else { throw ExteraUIIconError.corruptFile }
            if isDirectory {
                guard size == 0 else { throw ExteraUIIconError.invalidArchive }
            } else {
                files[name] = Data(result)
            }
            position = next
        }
        guard position == end else { throw ExteraUIIconError.invalidArchive }
        let fileNames = Set(paths.filter { !$0.1 }.map { $0.0 })
        for (name, _) in paths {
            var parts = name.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard !fileNames.contains(parts.joined(separator: "/")) else { throw ExteraUIIconError.unsafePath }
            }
        }
        return files
    }

    /// Deterministic UTF-8, unencrypted, stored ZIP. Readable by Android's .icons importer.
    public static func encode(_ files: [String: Data]) throws -> Data {
        guard !files.isEmpty, files.count <= maxEntries else { throw ExteraUIIconError.limitExceeded }
        var output = Data(), directory = Data()
        var total = 0
        func append(_ value: Int, _ width: Int, to data: inout Data) {
            for shift in 0 ..< width { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        for name in files.keys.sorted() {
            guard try path(name) == name, let data = files[name], data.count <= maxFileBytes,
                  data.count <= maxTotalBytes - total else { throw ExteraUIIconError.limitExceeded }
            total += data.count
            let filename = Data(name.utf8), offset = output.count, checksum = Int(crc32(data))
            for (value, width) in [(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,2),(33,2),(checksum,4),(data.count,4),(data.count,4),(filename.count,2),(0,2)] { append(value, width, to: &output) }
            output.append(filename); output.append(data)
            for (value, width) in [(0x02014b50,4),(20,2),(20,2),(0x800,2),(0,2),(0,2),(33,2),(checksum,4),(data.count,4),(data.count,4),(filename.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)] { append(value, width, to: &directory) }
            directory.append(filename)
        }
        let offset = output.count
        output.append(directory)
        for (value, width) in [(0x06054b50,4),(0,2),(0,2),(files.count,2),(files.count,2),(directory.count,4),(offset,4),(0,2)] { append(value, width, to: &output) }
        guard output.count <= maxArchiveBytes else { throw ExteraUIIconError.limitExceeded }
        return output
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
        return ~value
    }
    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        return value
    }
}

/// Bounded RFC 1951 decoder; no executable/archive helper or platform plugin is invoked.
private enum ExteraUIIconDeflate {
    private struct Bits {
        let bytes: [UInt8]
        var offset = 0
        mutating func take(_ count: Int) throws -> Int {
            guard count >= 0, offset + count <= bytes.count * 8 else { throw ExteraUIIconError.corruptFile }
            var value = 0
            for index in 0 ..< count { value |= Int((bytes[(offset + index) / 8] >> ((offset + index) % 8)) & 1) << index }
            offset += count
            return value
        }
    }
    private struct Huffman {
        var table: [Int: Int] = [:]
        init(_ lengths: [Int]) throws {
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths { guard (0 ... 15).contains(length) else { throw ExteraUIIconError.corruptFile }; if length > 0 { counts[length] += 1 } }
            var codes = [Int](repeating: 0, count: 16), code = 0, remaining = 1
            for length in 1 ... 15 {
                remaining = remaining * 2 - counts[length]
                guard remaining >= 0 else { throw ExteraUIIconError.corruptFile }
                code = (code + counts[length - 1]) << 1; codes[length] = code
            }
            for (symbol, length) in lengths.enumerated() where length > 0 {
                var reversed = 0, value = codes[length]
                for _ in 0 ..< length { reversed = reversed * 2 + (value & 1); value >>= 1 }
                table[(length << 16) | reversed] = symbol; codes[length] += 1
            }
        }
        func symbol(_ bits: inout Bits) throws -> Int {
            var code = 0
            for length in 1 ... 15 {
                code |= try bits.take(1) << (length - 1)
                if let symbol = table[(length << 16) | code] { return symbol }
            }
            throw ExteraUIIconError.corruptFile
        }
    }
    static func decode(_ bytes: [UInt8], size: Int) throws -> [UInt8] {
        var bits = Bits(bytes: bytes), output: [UInt8] = []
        output.reserveCapacity(size)
        var final = 0
        let lengths = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
        let lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
        let distances = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
        while final == 0 {
            final = try bits.take(1)
            let type = try bits.take(2)
            if type == 0 {
                bits.offset = (bits.offset + 7) & ~7
                let length = try bits.take(16), inverse = try bits.take(16)
                guard length ^ inverse == 65535, length <= size - output.count else { throw ExteraUIIconError.corruptFile }
                for _ in 0 ..< length { output.append(UInt8(try bits.take(8))) }
                continue
            }
            let literal: Huffman, distance: Huffman
            if type == 1 {
                literal = try Huffman((0 ..< 288).map { $0 < 144 ? 8 : ($0 < 256 ? 9 : ($0 < 280 ? 7 : 8)) })
                distance = try Huffman([Int](repeating: 5, count: 32))
            } else if type == 2 {
                let nl = try bits.take(5) + 257, nd = try bits.take(5) + 1, nc = try bits.take(4) + 4
                guard nl <= 286 else { throw ExteraUIIconError.corruptFile }
                // RFC 1951 code-length order (19 symbols).
                let codeOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
                var codeLengths = [Int](repeating: 0, count: 19)
                for index in 0 ..< nc { codeLengths[codeOrder[index]] = try bits.take(3) }
                let codes = try Huffman(codeLengths)
                var values: [Int] = []
                while values.count < nl + nd {
                    let symbol = try codes.symbol(&bits)
                    if symbol < 16 { values.append(symbol); continue }
                    let repeated: Int, count: Int
                    switch symbol {
                    case 16: guard let previous = values.last else { throw ExteraUIIconError.corruptFile }; repeated = previous; count = try bits.take(2) + 3
                    case 17: repeated = 0; count = try bits.take(3) + 3
                    case 18: repeated = 0; count = try bits.take(7) + 11
                    default: throw ExteraUIIconError.corruptFile
                    }
                    guard count <= nl + nd - values.count else { throw ExteraUIIconError.corruptFile }
                    values.append(contentsOf: repeatElement(repeated, count: count))
                }
                guard values[256] != 0 else { throw ExteraUIIconError.corruptFile }
                literal = try Huffman(Array(values.prefix(nl))); distance = try Huffman(Array(values.suffix(nd)))
            } else { throw ExteraUIIconError.corruptFile }
            while true {
                let symbol = try literal.symbol(&bits)
                if symbol == 256 { break }
                if symbol < 256 {
                    guard output.count < size else { throw ExteraUIIconError.corruptFile }
                    output.append(UInt8(symbol)); continue
                }
                guard (257 ... 285).contains(symbol) else { throw ExteraUIIconError.corruptFile }
                let index = symbol - 257
                let count = lengths[index] + (try bits.take(lengthExtra[index]))
                let d = try distance.symbol(&bits)
                guard d < 30 else { throw ExteraUIIconError.corruptFile }
                let extra = d < 4 ? 0 : d / 2 - 1
                let back = distances[d] + (try bits.take(extra))
                guard back <= output.count, count <= size - output.count else { throw ExteraUIIconError.corruptFile }
                for _ in 0 ..< count { output.append(output[output.count - back]) }
            }
        }
        guard output.count == size, (bits.offset + 7) / 8 == bytes.count else { throw ExteraUIIconError.corruptFile }
        return output
    }
}
