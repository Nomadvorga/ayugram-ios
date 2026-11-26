import CVosk
import Foundation

/// ZIP32 reader for the pinned official archives. Extraction is bounded and
/// streaming. ZIP64, encryption, links, ambiguous paths and extra roots fail.
/// The destination must be a newly created, private staging directory.
enum VoskSafeArchive {
    private struct Entry {
        let name: String
        let relative: [String]
        let flags: Int
        let method: Int
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
        let directory: Bool
    }

    private static func word(_ data: Data, _ offset: Int, _ length: Int) throws -> Int {
        guard offset >= 0, length <= data.count, offset <= data.count - length else { throw VoskSpeechError.unsafeArchive }
        return (0..<length).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
    }

    static func extract(archive: URL, destination: URL, model: VoskModelDescriptor, cancellation: VoskCancellation) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length == UInt64(model.archiveBytes), length >= 22 else { throw VoskSpeechError.integrityFailed }
        let tailSize = min(Int(length), 65557)
        try file.seek(toOffset: length - UInt64(tailSize))
        let tail = try file.voskRead(count: tailSize)
        var end: Int?
        for index in stride(from: tailSize - 22, through: 0, by: -1) {
            if try word(tail, index, 4) == 0x06054b50,
               index + 22 + (try word(tail, index + 20, 2)) == tailSize {
                end = index
                break
            }
        }
        guard let end else { throw VoskSpeechError.unsafeArchive }
        let count = try word(tail, end + 10, 2)
        let centralBytes = try word(tail, end + 12, 4)
        let centralOffset = try word(tail, end + 16, 4)
        guard try word(tail, end + 4, 2) == 0, try word(tail, end + 6, 2) == 0,
              try word(tail, end + 8, 2) == count,
              count == model.entryCount, count > 0, count < 65535,
              centralBytes <= 4 * 1024 * 1024,
              centralOffset + centralBytes == Int(length) - tailSize + end else { throw VoskSpeechError.unsafeArchive }
        try file.seek(toOffset: UInt64(centralOffset))
        let central = try file.voskRead(count: centralBytes)
        var entries: [Entry] = []
        var names = Set<String>()
        var position = 0
        var expandedTotal = 0
        for _ in 0..<count {
            try cancellation.check()
            guard try word(central, position, 4) == 0x02014b50 else { throw VoskSpeechError.unsafeArchive }
            let flags = try word(central, position + 8, 2)
            let method = try word(central, position + 10, 2)
            let crc = UInt32(try word(central, position + 16, 4))
            let compressed = try word(central, position + 20, 4)
            let expanded = try word(central, position + 24, 4)
            let nameBytes = try word(central, position + 28, 2)
            let extraBytes = try word(central, position + 30, 2)
            let commentBytes = try word(central, position + 32, 2)
            let mode = (try word(central, position + 38, 4) >> 16) & 0o170000
            let offset = try word(central, position + 42, 4)
            let next = position + 46 + nameBytes + extraBytes + commentBytes
            guard next <= central.count, flags & ~0x080e == 0, flags & 1 == 0,
                  method == 0 || method == 8, compressed != 0xffffffff, offset != 0xffffffff,
                  expanded <= model.largestEntryBytes, mode == 0 || mode == 0o100000 || mode == 0o040000,
                  try word(central, position + 34, 2) == 0 else { throw VoskSpeechError.unsafeArchive }
            let nameData = central.subdata(in: (position + 46)..<(position + 46 + nameBytes))
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty,
                  !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
                  !name.hasPrefix("/"), !name.contains("//") else { throw VoskSpeechError.unsafeArchive }
            let directory = name.hasSuffix("/")
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let components = directory ? Array(parts.dropLast()) : parts
            guard components.first == model.name,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
                  name.utf8.count <= 1024,
                  names.insert(components.joined(separator: "/").lowercased()).inserted,
                  !directory || (expanded == 0 && compressed == 0 && crc == 0 && method == 0),
                  mode != 0o040000 || directory,
                  offset + 30 <= centralOffset else { throw VoskSpeechError.unsafeArchive }
            expandedTotal += expanded
            guard expandedTotal <= model.expandedBytes else { throw VoskSpeechError.unsafeArchive }
            entries.append(Entry(name: name, relative: Array(components.dropFirst()), flags: flags, method: method, crc: crc,
                compressed: compressed, expanded: expanded, offset: offset, directory: directory))
            position = next
        }
        guard position == central.count, expandedTotal == model.expandedBytes else { throw VoskSpeechError.unsafeArchive }

        let fm = FileManager.default
        for entry in entries {
            try cancellation.check()
            var target = destination
            for part in entry.relative { target.appendPathComponent(part, isDirectory: false) }
            guard !entry.relative.isEmpty || entry.directory else { throw VoskSpeechError.unsafeArchive }
            // Every parent belongs to this operation's new staging directory. Inspect
            // each component so even pre-existing links cannot redirect a write.
            var parent = destination
            for part in entry.relative.dropLast() {
                parent.appendPathComponent(part, isDirectory: true)
                if fm.fileExists(atPath: parent.path) {
                    guard try fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw VoskSpeechError.unsafeArchive }
                } else { try fm.createDirectory(at: parent, withIntermediateDirectories: false) }
            }
            if entry.directory {
                if !fm.fileExists(atPath: target.path) { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
                guard try fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeDirectory else { throw VoskSpeechError.unsafeArchive }
                continue
            }
            guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else { throw VoskSpeechError.unsafeArchive }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try file.seek(toOffset: UInt64(entry.offset))
            let local = try file.voskRead(count: 30)
            guard try word(local, 0, 4) == 0x04034b50, try word(local, 6, 2) == entry.flags,
                  try word(local, 8, 2) == entry.method else { throw VoskSpeechError.unsafeArchive }
            let nameSize = try word(local, 26, 2)
            let extraSize = try word(local, 28, 2)
            let localName = try file.voskRead(count: nameSize)
            guard String(data: localName, encoding: .utf8) == entry.name,
                  entry.offset + 30 + nameSize + extraSize + entry.compressed <= centralOffset else { throw VoskSpeechError.unsafeArchive }
            try file.seek(toOffset: UInt64(entry.offset + 30 + nameSize + extraSize))
            var remaining = entry.compressed
            var writtenTotal = 0
            var crc: UInt32 = 0
            func write(_ data: Data) throws {
                if data.isEmpty { return }
                writtenTotal += data.count
                guard writtenTotal <= entry.expanded else { throw VoskSpeechError.unsafeArchive }
                crc = data.withUnsafeBytes { extera_vosk_crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                try output.write(contentsOf: data)
            }
            if entry.method == 0 {
                guard entry.compressed == entry.expanded else { throw VoskSpeechError.unsafeArchive }
                while remaining > 0 {
                    try cancellation.check()
                    let data = try file.voskRead(count: min(65536, remaining))
                    remaining -= data.count
                    try write(data)
                }
            } else {
                guard let inflater = extera_vosk_inflate_new() else { throw VoskSpeechError.storageFailure }
                defer { extera_vosk_inflate_free(inflater) }
                var ended = false
                while remaining > 0 {
                    try cancellation.check()
                    let data = try file.voskRead(count: min(65536, remaining))
                    remaining -= data.count
                    var offset = 0
                    repeat {
                        try cancellation.check()
                        var buffer = Data(count: 65536)
                        var consumed = 0
                        var produced = 0
                        let status = buffer.withUnsafeMutableBytes { dst in
                            data.withUnsafeBytes { src in
                                extera_vosk_inflate(inflater, src.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), data.count - offset,
                                    dst.bindMemory(to: UInt8.self).baseAddress!, 65536, &consumed, &produced)
                            }
                        }
                         guard status >= 0 else { throw VoskSpeechError.unsafeArchive }
                         if consumed == 0 && produced == 0 {
                             // A full output buffer can exhaust this input chunk
                             // exactly. zlib then needs the next compressed chunk.
                             guard status == 0, offset == data.count, remaining > 0 else { throw VoskSpeechError.unsafeArchive }
                             break
                         }
                        offset += consumed
                        buffer.count = produced
                        try write(buffer)
                        if status == 1 {
                            guard offset == data.count, remaining == 0 else { throw VoskSpeechError.unsafeArchive }
                            ended = true
                            break
                        }
                        // Continue draining a full output buffer even after input is consumed.
                        if offset == data.count && produced < 65536 { break }
                    } while true
                }
                guard ended else { throw VoskSpeechError.unsafeArchive }
            }
            guard writtenTotal == entry.expanded, crc == entry.crc else { throw VoskSpeechError.integrityFailed }
        }
        try cancellation.check()
    }
}
