import AVFoundation
import Foundation
import SwiftSignalKit

/// Reads only an already cached local audio file. Does not start a Telegram media download.
enum ExteraLyricsEmbedded {
    private final class Operation {
        private let lock = NSLock()
        private var cancelled = false
        private var asset: AVURLAsset?

        var isCancelled: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.cancelled
        }

        func setAsset(_ asset: AVURLAsset) {
            self.lock.lock()
            let cancelled = self.cancelled
            if !cancelled { self.asset = asset }
            self.lock.unlock()
            if cancelled { asset.cancelLoading() }
        }

        func cancel() {
            self.lock.lock()
            self.cancelled = true
            let asset = self.asset
            self.asset = nil
            self.lock.unlock()
            asset?.cancelLoading()
        }
    }

    static func read(cachedFilePath: String) -> Signal<ExteraLyricsDocument?, NoError> {
        return Signal<ExteraLyricsDocument?, NoError> { subscriber in
            let operation = Operation()
            DispatchQueue.global(qos: .utility).async {
                guard !operation.isCancelled else { return }
                guard FileManager.default.fileExists(atPath: cachedFilePath) else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                if let file = FileHandle(forReadingAtPath: cachedFilePath) {
                    // FLAC/Ogg comments live in bounded metadata/header packets. Never
                    // map the complete song just to inspect its lyrics tags.
                    let header = file.readData(ofLength: 4 * 1024 * 1024)
                    file.closeFile()
                    if let text = self.vorbisLyrics(header), let document = ExteraLyricsParser.parse(text, provider: "Embedded") {
                        guard !operation.isCancelled else { return }
                        subscriber.putNext(document)
                        subscriber.putCompletion()
                        return
                    }
                }
                guard !operation.isCancelled else { return }
                let asset = AVURLAsset(url: URL(fileURLWithPath: cachedFilePath))
                operation.setAsset(asset)
                asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "metadata"]) {
                    guard !operation.isCancelled else { return }
                    var result: ExteraLyricsDocument?
                    if asset.statusOfValue(forKey: "commonMetadata", error: nil) == .loaded {
                        var metadata = asset.commonMetadata
                        if asset.statusOfValue(forKey: "metadata", error: nil) == .loaded { metadata += asset.metadata }
                        for item in metadata {
                            let key = (item.key as? String ?? "").lowercased()
                            let identifier = item.identifier?.rawValue.lowercased() ?? ""
                            let commonKey = item.commonKey?.rawValue.lowercased() ?? ""
                            if commonKey == "lyrics" || key == "uslt" || key == "©lyr" || key == "lyrics" || identifier.hasSuffix("/uslt") || identifier.hasSuffix("/©lyr") {
                                if let text = item.stringValue, let document = ExteraLyricsParser.parse(text, provider: "Embedded") {
                                    if document.rank > (result?.rank ?? 0) { result = document }
                                }
                            }
                        }
                    }
                    guard !operation.isCancelled else { return }
                    subscriber.putNext(result)
                    subscriber.putCompletion()
                }
            }
            return ActionDisposable { operation.cancel() }
        }
        |> timeout(5.0, queue: .mainQueue(), alternate: .single(nil))
    }

    /// FLAC Vorbis comments, Ogg Vorbis and Ogg Opus headers. Returns only recognized
    /// lyric fields; the rest of the metadata stays local and is never sent to providers.
    static func vorbisLyrics(_ data: Data) -> String? {
        guard data.count <= 4 * 1024 * 1024 else { return nil }
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("fLaC".utf8)) {
            var offset = 4
            while offset + 4 <= bytes.count {
                let type = bytes[offset] & 0x7f
                let last = bytes[offset] & 0x80 != 0
                let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard length <= bytes.count - offset else { return nil }
                if type == 4 { return self.comments(bytes, start: offset, end: offset + length) }
                offset += length
                if last { break }
            }
        } else if bytes.starts(with: Array("OggS".utf8)) {
            var offset = 0
            var packets: [UInt32: [UInt8]] = [:]
            var pages = 0
            while offset + 27 <= bytes.count, pages < 128 {
                pages += 1
                guard Array(bytes[offset ..< offset + 4]) == Array("OggS".utf8), bytes[offset + 4] == 0 else { return nil }
                let serial = self.uint32(bytes, offset + 14)
                let segments = Int(bytes[offset + 26])
                guard offset + 27 + segments <= bytes.count else { return nil }
                var body = offset + 27 + segments
                var packet = packets[serial] ?? []
                if bytes[offset + 5] & 1 == 0 { packet.removeAll(keepingCapacity: true) }
                for index in 0 ..< segments {
                    let length = Int(bytes[offset + 27 + index])
                    guard body + length <= bytes.count, packet.count + length <= ExteraLyricsParser.maximumBytes else { return nil }
                    packet.append(contentsOf: bytes[body ..< body + length])
                    body += length
                    if length < 255 {
                        if packet.starts(with: [3] + Array("vorbis".utf8)), let text = self.comments(packet, start: 7, end: packet.count) { return text }
                        if packet.starts(with: Array("OpusTags".utf8)), let text = self.comments(packet, start: 8, end: packet.count) { return text }
                        packet.removeAll(keepingCapacity: true)
                    }
                }
                guard packets.count < 16 || packets[serial] != nil else { return nil }
                packets[serial] = packet
                offset = body
            }
        }
        return nil
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func comments(_ bytes: [UInt8], start: Int, end: Int) -> String? {
        var position = start
        func length() -> Int? {
            guard position + 4 <= end else { return nil }
            let value = Int(self.uint32(bytes, position))
            position += 4
            guard value <= end - position else { return nil }
            return value
        }
        guard let vendorLength = length() else { return nil }
        position += vendorLength
        guard position + 4 <= end else { return nil }
        let count = Int(self.uint32(bytes, position))
        position += 4
        guard count <= 20000 else { return nil }
        var plain: String?
        for _ in 0 ..< count {
            guard let size = length() else { return nil }
            let field = String(bytes: bytes[position ..< position + size], encoding: .utf8)
            position += size
            guard let field, let equals = field.firstIndex(of: "=") else { continue }
            let name = field[..<equals].uppercased()
            guard ["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "UNSYNCED LYRICS"].contains(name) else { continue }
            let text = String(field[field.index(after: equals)...])
            guard text.utf8.count <= ExteraLyricsParser.maximumBytes else { continue }
            if name == "SYNCEDLYRICS" { return text }
            if plain == nil { plain = text }
        }
        return plain
    }
}
