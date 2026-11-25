import Foundation

/// Serial, bounded writes. Only one message and one 512 KiB media chunk are
/// serialized at once; no full chat or account history is accumulated in memory.
final class ExteraTakeoutWriter {
    let directory: URL
    let contentsURL: URL
    let archiveURL: URL
    private let options: ExteraTakeoutOptions
    private var json: FileHandle?
    private var html: FileHandle?
    private var chatOpen = false
    private var firstChat = true
    private var firstMessage = true
    private(set) var bytesWritten: Int64 = 0
    private(set) var mediaCount = 0
    private let encoder = JSONEncoder()

    init(options: ExteraTakeoutOptions) throws {
        self.options = options
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("extera-takeout-\(UUID().uuidString)", isDirectory: true)
        self.contentsURL = self.directory.appendingPathComponent("export", isDirectory: true)
        self.archiveURL = self.directory.appendingPathComponent("telegram-export.zip")
        do {
            try FileManager.default.createDirectory(at: self.contentsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if options.format != .html {
                let handle = try Self.create(self.contentsURL.appendingPathComponent("result.json"))
                self.json = handle
                try self.write(Data("{\"schema\":1,\"scope\":\"cloud_chat_histories\",\"order\":\"newest_first_per_split\",\"chats\":[".utf8), to: handle)
            }
            if options.format != .json {
                let handle = try Self.create(self.contentsURL.appendingPathComponent("index.html"))
                self.html = handle
                try self.write(Data("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; media-src 'self'\"><title>Telegram cloud chat export</title><style>body{font:16px system-ui;max-width:900px;margin:24px auto;padding:0 16px}article{border-top:1px solid #bbb;padding:12px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}small{color:#555}a{overflow-wrap:anywhere}</style></head><body><h1>Telegram cloud chat export</h1><p>Newest messages first within each server split. See manifest.json for scope and omissions.</p>".utf8), to: handle)
            }
        } catch {
            try? FileManager.default.removeItem(at: self.directory)
            throw error
        }
    }

    static func escapeHTML(_ value: String) -> String {
        return value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func create(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ExteraTakeoutError.io }
        return try FileHandle(forWritingTo: url)
    }

    private func write(_ data: Data, to handle: FileHandle) throws {
        guard Int64(data.count) <= self.options.maximumExportBytes - self.bytesWritten else { throw ExteraTakeoutError.outputLimit }
        try handle.write(contentsOf: data)
        self.bytesWritten += Int64(data.count)
    }

    func beginChat(_ chat: ExteraTakeoutChatRecord) throws {
        try self.endChat()
        if let json = self.json {
            var object = try self.encoder.encode(chat)
            guard object.last == 125 else { throw ExteraTakeoutError.io }
            object.removeLast()
            if !self.firstChat { try self.write(Data(",".utf8), to: json) }
            try self.write(object, to: json)
            try self.write(Data(",\"messages\":[".utf8), to: json)
        }
        if let html = self.html {
            try self.write(Data("<section><h2>\(Self.escapeHTML(chat.title))</h2><p>\(Self.escapeHTML(chat.id)) · \(Self.escapeHTML(chat.type)) · split \(chat.split)</p>".utf8), to: html)
        }
        self.firstChat = false
        self.firstMessage = true
        self.chatOpen = true
    }

    func append(_ message: ExteraTakeoutMessageRecord) throws {
        guard self.chatOpen else { throw ExteraTakeoutError.io }
        if let json = self.json {
            if !self.firstMessage { try self.write(Data(",".utf8), to: json) }
            try self.write(try self.encoder.encode(message), to: json)
        }
        if let html = self.html {
            var value = "<article><small>#\(message.id) · \(Self.escapeHTML(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(message.date))))) · \(Self.escapeHTML(message.sender ?? "unknown"))</small><pre>\(Self.escapeHTML(message.text))</pre>"
            if let action = message.serviceAction { value += "<p>Service: \(Self.escapeHTML(action))</p>" }
            if let media = message.media {
                if let path = media.path { value += "<p><a href=\"\(Self.escapeHTML(path))\">\(Self.escapeHTML(media.name ?? media.type))</a></p>" }
                else { value += "<p>Media: \(Self.escapeHTML(media.type)) (\(Self.escapeHTML(media.skippedReason ?? "not_downloaded")))</p>" }
            }
            value += "</article>"
            try self.write(Data(value.utf8), to: html)
        }
        self.firstMessage = false
    }

    func endChat() throws {
        guard self.chatOpen else { return }
        if let json = self.json { try self.write(Data("]}".utf8), to: json) }
        if let html = self.html { try self.write(Data("</section>".utf8), to: html) }
        self.chatOpen = false
    }

    func createMedia(extension suffix: String) throws -> (String, FileHandle) {
        guard self.mediaCount < 50000 else { throw ExteraTakeoutError.outputLimit }
        self.mediaCount += 1
        let folder = self.contentsURL.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Names from the server never become filesystem paths.
        let safeSuffix = suffix.utf8.count <= 8 && suffix.utf8.allSatisfy { (97 ... 122).contains($0) || (48 ... 57).contains($0) } ? suffix : "bin"
        let relative = "media/\(self.mediaCount).\(safeSuffix)"
        return (relative, try Self.create(self.contentsURL.appendingPathComponent(relative)))
    }

    func appendMedia(_ data: Data, to handle: FileHandle) throws { try self.write(data, to: handle) }

    func removeMedia(_ path: String) { try? FileManager.default.removeItem(at: self.contentsURL.appendingPathComponent(path)) }

    func finalize(messages: Int64, skippedMedia: Int) throws {
        try self.endChat()
        if let json = self.json { try self.write(Data("]}".utf8), to: json); try json.close(); self.json = nil }
        if let html = self.html { try self.write(Data("</body></html>".utf8), to: html); try html.close(); self.html = nil }
        let manifest: [String: Any] = [
            "schema": 1, "scope": "cloud_chat_histories", "messages": messages, "skipped_media": skippedMedia,
            "chat_types": self.options.chatTypes.rawValue, "media_mode": self.options.media.rawValue,
            "maximum_file_size": self.options.maximumFileSize, "from_timestamp": self.options.fromTimestamp.map { $0 as Any } ?? NSNull(),
            "until_timestamp": self.options.untilTimestamp.map { $0 as Any } ?? NSNull(), "order": "newest_first_per_split",
            "omissions": ["Secret chats and community dialog containers", "Account profile, profile photos, contacts, sessions and other-data takeout", "Stories and saved profile music", "Message entity formatting, reactions, polls, rich-message content and service-action details", "Topic-specific navigation, migrations merged into one chat, deleted/unavailable server history", "Unsupported media, file-reference refresh and CDN redirects; each skipped item has a reason"],
            "left_channels_requested": self.options.includeLeftChannels
        ]
        let handle = try Self.create(self.contentsURL.appendingPathComponent("manifest.json"))
        defer { try? handle.close() }
        try self.write(try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), to: handle)
    }

    func closeAndRemove() {
        try? self.json?.close(); self.json = nil
        try? self.html?.close(); self.html = nil
        try? FileManager.default.removeItem(at: self.directory)
    }

    deinit { try? self.json?.close(); try? self.html?.close() }
}

/// Uncompressed ZIP32 avoids a new module dependency. Content and the central directory
/// are bounded; cancellation is checked between 256 KiB blocks during packaging.
enum ExteraTakeoutArchive {
    private struct Entry { let name: Data; let size: UInt32; let crc: UInt32; let offset: UInt32 }
    private static let crcTable: [UInt32] = (0 ..< 256).map { value in
        var crc = UInt32(value)
        for _ in 0 ..< 8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }

    private static func crc(_ data: Data, previous: UInt32) -> UInt32 {
        var value = previous
        for byte in data { value = self.crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
        return value
    }

    private static func data(_ values: [(UInt32, Int)]) -> Data {
        var result = Data()
        for (value, count) in values { for shift in 0 ..< count { result.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
        return result
    }

    static func create(directory: URL, destination: URL, cancelled: () -> Bool) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ExteraTakeoutError.io }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var offset: UInt64 = 0
        func write(_ data: Data) throws {
            guard !cancelled() else { throw ExteraTakeoutError.io }
            guard offset + UInt64(data.count) < UInt64(UInt32.max) else { throw ExteraTakeoutError.outputLimit }
            try output.write(contentsOf: data)
            offset += UInt64(data.count)
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw ExteraTakeoutError.io }
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isSymbolicLink != true else { throw ExteraTakeoutError.io }
            guard attributes.isRegularFile == true else { continue }
            guard entries.count < 60000, let fileSize = attributes.fileSize, fileSize >= 0, UInt64(fileSize) < UInt64(UInt32.max) else { throw ExteraTakeoutError.outputLimit }
            let prefix = directory.path + "/"
            guard url.path.hasPrefix(prefix) else { throw ExteraTakeoutError.io }
            let name = Data(url.path.dropFirst(prefix.count).utf8)
            guard name.count < 65536 else { throw ExteraTakeoutError.outputLimit }
            let start = UInt32(offset)
            // Bit 3: CRC/sizes follow data; bit 11: names are UTF-8.
            try write(self.data([(0x04034b50, 4), (20, 2), (0x0808, 2), (0, 2), (0, 2), (33, 2), (0, 4), (0, 4), (0, 4), (UInt32(name.count), 2), (0, 2)]))
            try write(name)
            let input = try FileHandle(forReadingFrom: url)
            var count: UInt64 = 0
            var checksum: UInt32 = 0xffffffff
            do {
                while true {
                    guard !cancelled() else { throw ExteraTakeoutError.io }
                    let block = try input.read(upToCount: 256 * 1024) ?? Data()
                    if block.isEmpty { break }
                    count += UInt64(block.count)
                    guard count <= UInt64(fileSize) else { throw ExteraTakeoutError.io }
                    checksum = self.crc(block, previous: checksum)
                    try write(block)
                }
                try input.close()
            } catch { try? input.close(); throw error }
            guard count == UInt64(fileSize) else { throw ExteraTakeoutError.io }
            checksum ^= 0xffffffff
            let size = UInt32(count)
            try write(self.data([(0x08074b50, 4), (checksum, 4), (size, 4), (size, 4)]))
            entries.append(Entry(name: name, size: size, crc: checksum, offset: start))
        }
        let centralOffset = UInt32(offset)
        for entry in entries {
            try write(self.data([(0x02014b50, 4), (20, 2), (20, 2), (0x0808, 2), (0, 2), (0, 2), (33, 2), (entry.crc, 4), (entry.size, 4), (entry.size, 4), (UInt32(entry.name.count), 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (entry.offset, 4)]))
            try write(entry.name)
        }
        let centralSize = UInt32(offset) - centralOffset
        try write(self.data([(0x06054b50, 4), (0, 2), (0, 2), (UInt32(entries.count), 2), (UInt32(entries.count), 2), (centralSize, 4), (centralOffset, 4), (0, 2)]))
        try output.synchronize()
        try output.close()
    }
}
