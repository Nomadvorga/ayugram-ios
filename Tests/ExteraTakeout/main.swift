import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Compiles the production models and writer directly; see README.md.
var checks = 0
var phase = "option validation"
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), "\(phase): \(message)")
}
func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }

// Read the stored entries through the central directory, independently of the
// production writer. Check actual relative names and contents for every root form.
func archiveFiles(at url: URL) throws -> [String: Data] {
    let bytes = [UInt8](try Data(contentsOf: url))
    func number(_ offset: Int, _ count: Int) -> Int {
        check(offset >= 0 && offset + count <= bytes.count, "ZIP field is in bounds")
        return (0 ..< count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
    }
    let end = bytes.count - 22
    check(number(end, 4) == 0x06054b50, "ZIP end of central directory")
    var offset = number(end + 16, 4)
    var files: [String: Data] = [:]
    for _ in 0 ..< number(end + 10, 2) {
        check(number(offset, 4) == 0x02014b50, "ZIP central directory entry")
        check(number(offset + 10, 2) == 0, "ZIP entry is stored without compression")
        let size = number(offset + 24, 4)
        let nameSize = number(offset + 28, 2)
        let local = number(offset + 42, 4)
        let nameStart = offset + 46
        check(nameStart + nameSize <= bytes.count, "ZIP name is in bounds")
        let name = String(decoding: bytes[nameStart ..< nameStart + nameSize], as: UTF8.self)
        check(!name.hasPrefix("/") && !name.split(separator: "/").contains(".."), "ZIP name is relative and cannot escape its root")
        check(files[name] == nil, "ZIP names are unique")
        check(number(local, 4) == 0x04034b50, "ZIP local header matches the central entry")
        let contents = local + 30 + number(local + 26, 2) + number(local + 28, 2)
        check(contents + size <= bytes.count, "ZIP contents are in bounds")
        files[name] = Data(bytes[contents ..< contents + size])
        offset += 46 + nameSize + number(offset + 30, 2) + number(offset + 32, 2)
    }
    return files
}

func runChecks() throws {
    var options = ExteraTakeoutOptions()
    try options.validate()
    check(options.sessionFlags == (1 << 1 | 1 << 2 | 1 << 3), "Default session enables users and both group classes")
    options.chatTypes = .all
    options.media = .photosAndFiles
    check(options.sessionFlags == 62, "All message/file flags match TL flags; contacts excluded")
    options.fromTimestamp = 10
    options.untilTimestamp = 20
    check(!options.includes(date: 9) && options.includes(date: 10) && options.includes(date: 19) && !options.includes(date: 20), "Inclusive from / exclusive until")
    options.untilTimestamp = 10
    check(rejects { try options.validate() }, "Invalid date order rejected")
    options.untilTimestamp = 20
    options.chatTypes = []
    check(rejects { try options.validate() }, "No chat types rejected")
    options.chatTypes = .all
    options.maximumFileSize = 513 * 1024 * 1024
    check(rejects { try options.validate() }, "Oversized download limit rejected")
    if case let .serverWait(seconds) = ExteraTakeoutError.server(code: 420, text: "TAKEOUT_INIT_DELAY_3600") { check(seconds == 3600, "Takeout authorization wait") } else { preconditionFailure("Expected takeout wait") }
    if case let .floodWait(seconds) = ExteraTakeoutError.server(code: 420, text: "FLOOD_WAIT_30") { check(seconds == 30, "Flood wait") } else { preconditionFailure("Expected flood wait") }
    if case let .rpc(_, description) = ExteraTakeoutError.server(code: 500, text: "unexpected private payload") { check(description == "REQUEST_FAILED", "Arbitrary error payload redacted") } else { preconditionFailure("Expected RPC error") }

    phase = "streamed JSON, HTML and media serialization"
    options = ExteraTakeoutOptions()
    options.format = .jsonAndHTML
    let writer = try ExteraTakeoutWriter(options: options)
    defer { writer.closeAndRemove() }
    let hostile = "<script>alert('x')</script> & 🌍 \"quote\""
    try writer.beginChat(.init(id: "user1", title: hostile, type: "personal", split: 0, left: false))
    try writer.append(.init(id: 1, date: 1700000000, sender: "user2", outgoing: false, text: hostile, serviceAction: nil, replyToMessageId: nil, groupedId: nil, media: nil))
    let media = try writer.createMedia(extension: "../../bad")
    try writer.appendMedia(Data([0, 1, 2, 3, 255]), to: media.1)
    try media.1.close()
    check(media.0 == "media/1.bin", "Server filename cannot become a path")
    try writer.endChat()
    try writer.beginChat(.init(id: "group2", title: "Empty", type: "private_group", split: 1, left: false))
    try writer.finalize(messages: 1, skippedMedia: 0)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: writer.contentsURL.appendingPathComponent("result.json"))) as! [String: Any]
    let chats = json["chats"] as! [[String: Any]]
    check(chats.count == 2, "Both streamed chats form valid JSON")
    check((chats[1]["messages"] as! [Any]).isEmpty, "Empty final chat closes correctly")
    check(((chats[0]["messages"] as! [[String: Any]])[0]["text"] as! String) == hostile, "JSON retains exact Unicode message text")
    let html = try String(contentsOf: writer.contentsURL.appendingPathComponent("index.html"), encoding: .utf8)
    check(!html.contains("<script>"), "HTML escapes untrusted message and title")
    check(html.contains("&lt;script&gt;") && html.contains("Content-Security-Policy"), "HTML escape and CSP")
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: writer.contentsURL.appendingPathComponent("manifest.json"))) as! [String: Any]
    check((manifest["omissions"] as! [String]).count >= 5, "Archive discloses omitted domains")

    phase = "packaging production export (root: \(writer.contentsURL.path), canonical: \(writer.contentsURL.resolvingSymlinksInPath().path))"
    try ExteraTakeoutArchive.create(directory: writer.contentsURL, destination: writer.archiveURL, cancelled: { false })
    let exported = try archiveFiles(at: writer.archiveURL)
    check(Set(exported.keys) == Set(["result.json", "index.html", "manifest.json", "media/1.bin"]), "ZIP contains exactly the relative export paths")
    check(exported["media/1.bin"] == Data([0, 1, 2, 3, 255]), "ZIP preserves binary media")
    if CommandLine.arguments.count > 1 {
        phase = "copying ZIP fixture to \(CommandLine.arguments[1]) (destination must not exist)"
        try FileManager.default.copyItem(at: writer.archiveURL, to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }

    phase = "setting up archive path regression fixtures"
    let root = writer.directory.appendingPathComponent("path-regression", isDirectory: true)
    let nested = root.appendingPathComponent("nested space", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let payload = Data([0, 255, 80, 75, 0])
    try payload.write(to: nested.appendingPathComponent("🌍.bin"))
    try Data().write(to: root.appendingPathComponent("empty.txt"))
    let alias = writer.directory.appendingPathComponent("root-alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let roots: [(String, URL)] = [
        ("directory URL", root),
        ("URL without directory hint", URL(fileURLWithPath: root.path, isDirectory: false)),
        ("trailing slash", URL(fileURLWithPath: root.path + "/", isDirectory: true)),
        ("dot components", URL(fileURLWithPath: root.path + "/nested space/..", isDirectory: true)),
        ("canonical path", root.resolvingSymlinksInPath()),
        ("symlink root alias", alias)
    ]
    for (index, fixture) in roots.enumerated() {
        phase = "packaging path regression: \(fixture.0) (root: \(fixture.1.path), canonical: \(fixture.1.resolvingSymlinksInPath().path))"
        let destination = writer.directory.appendingPathComponent("path-\(index).zip")
        try ExteraTakeoutArchive.create(directory: fixture.1, destination: destination, cancelled: { false })
        let files = try archiveFiles(at: destination)
        check(files == ["empty.txt": Data(), "nested space/🌍.bin": payload], "\(fixture.0) preserves exact relative names and contents")
    }

    phase = "rejecting symbolic links inside the archive root"
    let linkedFile = root.appendingPathComponent("outside-file")
    try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: writer.contentsURL.appendingPathComponent("result.json"))
    check(rejects { try ExteraTakeoutArchive.create(directory: root, destination: writer.directory.appendingPathComponent("linked-file.zip"), cancelled: { false }) }, "Canonicalization still rejects symbolic link files")
    try FileManager.default.removeItem(at: linkedFile)
    let linkedDirectory = root.appendingPathComponent("outside-directory", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: writer.contentsURL)
    check(rejects { try ExteraTakeoutArchive.create(directory: root, destination: writer.directory.appendingPathComponent("linked-directory.zip"), cancelled: { false }) }, "Canonicalization still rejects symbolic link directories")

    phase = "packaging cancellation"
    let cancelledURL = writer.directory.appendingPathComponent("cancelled.zip")
    check(rejects { try ExteraTakeoutArchive.create(directory: writer.contentsURL, destination: cancelledURL, cancelled: { true }) }, "Packaging honours cancellation")

    phase = "output byte limit and cleanup"
    var limited = ExteraTakeoutOptions()
    limited.maximumExportBytes = 1024 * 1024
    let bounded = try ExteraTakeoutWriter(options: limited)
    defer { bounded.closeAndRemove() }
    try bounded.beginChat(.init(id: "user1", title: "Limit", type: "personal", split: 0, left: false))
    check(rejects { try bounded.append(.init(id: 1, date: 1, sender: nil, outgoing: false, text: String(repeating: "x", count: 1024 * 1024 + 1), serviceAction: nil, replyToMessageId: nil, groupedId: nil, media: nil)) }, "Output limit fails instead of truncating success")
    let removed = bounded.directory
    bounded.closeAndRemove()
    check(!FileManager.default.fileExists(atPath: removed.path), "Failure/cancellation removes temporary directory")
    print("Passed \(checks) production takeout model/writer checks")
}

do {
    try runChecks()
} catch {
    FileHandle.standardError.write(Data("FAIL: \(phase) after \(checks) checks: \(String(reflecting: error))\n".utf8))
    exit(1)
}
