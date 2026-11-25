import Foundation

// Compiles the production models and writer directly; see README.md.
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }

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

try ExteraTakeoutArchive.create(directory: writer.contentsURL, destination: writer.archiveURL, cancelled: { false })
check((try? Data(contentsOf: writer.archiveURL).prefix(4)) == Data([0x50, 0x4b, 3, 4]), "ZIP local header")
if CommandLine.arguments.count > 1 {
    try FileManager.default.copyItem(at: writer.archiveURL, to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
let cancelledURL = writer.directory.appendingPathComponent("cancelled.zip")
check(rejects { try ExteraTakeoutArchive.create(directory: writer.contentsURL, destination: cancelledURL, cancelled: { true }) }, "Packaging honours cancellation")

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
