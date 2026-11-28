// Host check for the settings backup format. Not part of the app:
//   swiftc -warnings-as-errors -o /tmp/ayu-backup-tests AyuGram/AyuSettingsBackup/Sources/*.swift AyuGram/AyuSettingsBackup/Tests/*.swift && /tmp/ayu-backup-tests

import Foundation

var passed = 0
var failures: [String] = []

func check(_ label: String, _ expected: String?, _ actual: String?) {
    if expected == actual {
        passed += 1
    } else {
        failures.append("\(label)\n      expected: \(expected ?? "<none>")\n      actual:   \(actual ?? "<none>")")
    }
}

func hex(_ text: String) -> String {
    return text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
}

// "A" is byte 65 = 5 * 11 + 10; "{" is 123 = 1 * 121 + 0 * 11 + 2.
check("encode A", "2001 2002 206a 206f", hex(InvisibleEncryptor.encode("A")))
check("encode {}", "2001 2002 200b 200a 200c 2000 200b 200a 202f", hex(InvisibleEncryptor.encode("{}")))
check("encode empty", "2001 2002", hex(InvisibleEncryptor.encode("")))
check("decode A", "A", InvisibleEncryptor.decode("\u{2001}\u{2002}\u{206A}\u{206F}"))
check("round trip", "{\"ключ\": \"значение 😀\"}", InvisibleEncryptor.decode(InvisibleEncryptor.encode("{\"ключ\": \"значение 😀\"}")))
check("decode plain text", nil, InvisibleEncryptor.decode("{}"))
check("decode foreign character", nil, InvisibleEncryptor.decode("\u{2001}\u{2002}\u{206A}x"))
check("decode too large a group", nil, InvisibleEncryptor.decode("\u{2001}\u{2002}\u{206F}\u{206F}\u{206F}"))
check("decode broken UTF-8", nil, InvisibleEncryptor.decode("\u{2001}\u{2002}\u{200B}\u{206C}\u{202F}"))
check("is encrypted", "true", "\(InvisibleEncryptor.isEncrypted(InvisibleEncryptor.encode("{}")))")
check("is encrypted with a line break", "true", "\(InvisibleEncryptor.isEncrypted(InvisibleEncryptor.encode("{}") + "\n"))")
check("plain is not encrypted", "false", "\(InvisibleEncryptor.isEncrypted("{}"))")
check("empty is not encrypted", "false", "\(InvisibleEncryptor.isEncrypted(""))")

let android = """
{
  "exteraconfig": {
    "relativeLastSeen": true,
    "avatarCorners": 12.5,
    "doubleTapAction": 3,
    "targetLang": "ru",
    "pinnedPlugins": ["a", "b"],
    "nested": {"x": 1},
    "nothing": null
  },
  "mainconfig1": {
    "fons_size": 16.0
  },
  "notAGroup": 5
}
"""
if let document = ExteraBackupDocument(fileData: Data(android.utf8)) {
    let extera = document.configs[ExteraBackupDocument.exteraConfig] ?? [:]
    check("parse groups", "exteraconfig,mainconfig", document.configs.keys.sorted().joined(separator: ","))
    check("parse bool", "true", extera["relativeLastSeen"]?.boolValue.map { "\($0)" })
    check("parse bool is not a number", nil, extera["relativeLastSeen"]?.intValue.map { "\($0)" })
    check("parse float", "12.5", extera["avatarCorners"]?.floatValue.map { "\($0)" })
    check("parse float is not an int", nil, extera["avatarCorners"]?.intValue.map { "\($0)" })
    check("parse int", "3", extera["doubleTapAction"]?.intValue.map { "\($0)" })
    check("parse int is not a bool", nil, extera["doubleTapAction"]?.boolValue.map { "\($0)" })
    check("parse string", "ru", extera["targetLang"]?.stringValue)
    check("parse strings", "strings([\"a\", \"b\"])", extera["pinnedPlugins"].map { "\($0)" })
    check("parse skips objects and nulls", "5", "\(extera.count)")
    check("parse numbered main group", "16", document.configs[ExteraBackupDocument.mainConfig]?["fons_size"]?.intValue.map { "\($0)" })

    let encrypted = document.fileData()
    check("file is encrypted", "true", "\(InvisibleEncryptor.isEncrypted(String(data: encrypted, encoding: .utf8) ?? ""))")
    check("file round trip", "true", "\(ExteraBackupDocument(fileData: encrypted) == document)")
    check("plain file round trip", "true", "\(ExteraBackupDocument(fileData: document.fileData(encrypt: false)) == document)")
    check("json keeps integers whole", "true", "\(document.json().contains("\"doubleTapAction\" : 3,"))")
} else {
    check("parse", "document", nil)
}
check("main group wins over a numbered one", "1", ExteraBackupDocument(fileData: Data("{\"mainconfig\":{\"a\":1},\"mainconfig2\":{\"a\":2}}".utf8))?.configs["mainconfig"]?["a"]?.intValue.map { "\($0)" })
check("not json", nil, ExteraBackupDocument(fileData: Data("hello".utf8)).map { _ in "document" })
check("json array", nil, ExteraBackupDocument(fileData: Data("[1]".utf8)).map { _ in "document" })
check("too large", nil, ExteraBackupDocument(fileData: Data(count: ExteraBackupDocument.maxFileSize + 1)).map { _ in "document" })
check("empty groups are left out", "{\n\n}", ExteraBackupDocument(configs: ["exteraconfig": [:]]).json())
check("backup file name", "true,true,false,false", ["a.extera", "B.EXTERA", "a.txt", nil].map { "\(ExteraBackupDocument.isBackupFile(name: $0))" }.joined(separator: ","))
let name = ExteraBackupDocument.generateName()
check("generated name", "true", "\(name.hasPrefix("backup-") && name.hasSuffix(".extera") && name.count == 18)")

// Schema: export, validation, difference count, apply.
do {
    var flag = false
    var level = 1
    var corners = 28.0
    var language = ""
    var camera = 0
    let schema = ExteraBackupSchema(entries: [
        .bool("flag", get: { flag }, set: { flag = $0 }),
        .int("level", range: 0 ... 3, get: { level }, accepts: { $0 != 2 }, set: { level = $0 }),
        .float("corners", range: 0.0 ... 28.0, get: { corners }, stored: { ($0 / 4.0).rounded() * 4.0 }, set: { corners = $0 }),
        .string("language", get: { language.isEmpty ? nil : language }, accepts: { !$0.isEmpty }, set: { language = $0 }),
        .int("camera", group: ExteraBackupDocument.iosConfig, range: 0 ... 2, get: { camera }, set: { camera = $0 })
    ])
    let exported = schema.export()
    check("schema export groups", "ayugramios,exteraconfig", exported.configs.keys.sorted().joined(separator: ","))
    check("schema export leaves out unset", "corners,flag,level", exported.configs["exteraconfig"]?.keys.sorted().joined(separator: ","))
    check("schema export differs from itself", "0", "\(schema.differenceCount(exported))")
    check("schema recognizes its export", "true", "\(schema.recognizes(exported))")

    let incoming = ExteraBackupDocument(fileData: Data("""
    {"exteraconfig": {"flag": true, "level": 3.0, "corners": 13, "language": "ru", "unknown": 1},
     "ayugramios": {"camera": 2}, "aiconfig": {"roles": "x"}}
    """.utf8))!
    check("schema difference", "5", "\(schema.differenceCount(incoming))")
    check("schema apply count", "5", "\(schema.apply(incoming))")
    check("schema applied", "true 3 12.0 ru 2", "\(flag) \(level) \(corners) \(language) \(camera)")
    check("schema no difference after apply", "0", "\(schema.differenceCount(incoming))")

    let bad = ExteraBackupDocument(fileData: Data("""
    {"exteraconfig": {"flag": 1, "level": 2, "corners": 40, "language": "", "camera": 1},
     "ayugramios": {"camera": 2.5}}
    """.utf8))!
    check("schema refuses wrong types and ranges", "false", "\(schema.recognizes(bad))")
    check("schema refused values change nothing", "0", "\(schema.apply(bad))")
    check("schema state kept", "true 3 12.0 ru 2", "\(flag) \(level) \(corners) \(language) \(camera)")
    let mixed = ExteraBackupDocument(fileData: Data("{\"exteraconfig\": {\"flag\": false, \"level\": 9}}".utf8))!
    check("schema mixed difference", "1", "\(schema.differenceCount(mixed))")
    check("schema mixed apply", "1", "\(schema.apply(mixed))")
    check("schema mixed state", "false 3", "\(flag) \(level)")
    check("schema foreign file", "false", "\(schema.recognizes(ExteraBackupDocument(fileData: Data("{\"aiconfig\": {\"roles\": \"x\"}}".utf8))!))")
}

for failure in failures {
    print("FAIL  \(failure)")
}
print("\(passed) passed, \(failures.count) failed")
exit(failures.isEmpty ? 0 : 1)
