import Foundation

// Only the preferences adapter is replaced. Compile the production ExteraPillSettings.swift and
// ExteraPillStrings.swift alongside this file: no copied path/format/import implementation.
final class AyuSettingsStore: @unchecked Sendable {
    static let suiteName = "ExteraPillHostTests.\(UUID().uuidString)"
    static let shared = AyuSettingsStore()
    let userDefaults = UserDefaults(suiteName: AyuSettingsStore.suiteName)!
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum ExteraPillHostTests {
    private static var assertions = 0

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(description: message) }
        self.assertions += 1
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        var threw = false
        do { try operation() } catch { threw = true }
        try self.expect(threw, message)
    }

    static func main() throws {
        defer { AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: AyuSettingsStore.suiteName) }
        try self.paths()
        try self.formatting()
        try self.validation()
        try self.documentsAndPersistence()
        try self.localization()
        print("PASS: \(self.assertions) production pill path/format/validation/import/persistence/localization assertions")
    }

    private static func paths() throws {
        let data = Data(#"{"data":{"items":[{"value":12.5},{"value":8}]},"key.with.dots":{"a\"b":"quoted"},"empty":[],"null":null,"flag":true}"#.utf8)
        let root = try JSONSerialization.jsonObject(with: data)
        for path in ["data.items[0].value", "$.data.items[0].value"] {
            try self.expect((try ExteraPillJSONPath.resolve(root, path: path) as? NSNumber)?.doubleValue == 12.5, "Nested path: \(path)")
        }
        try self.expect((try ExteraPillJSONPath.resolve(root, path: "data.items[-1].value") as? NSNumber)?.intValue == 8, "Negative index resolves last item")
        try self.expect((try ExteraPillJSONPath.resolve(root, path: "data.items[-2].value") as? NSNumber)?.doubleValue == 12.5, "Negative index lower bound")
        try self.expect((try ExteraPillJSONPath.resolve(root, path: "data.items.length") as? Int) == 2, "Array length")
        try self.expect((try ExteraPillJSONPath.resolve(root, path: "empty.length") as? Int) == 0, "Empty array length")
        try self.expect((try ExteraPillJSONPath.resolve(root, path: #"["key.with.dots"]["a\"b"]"#) as? String) == "quoted", "Quoted dotted and escaped keys")
        try self.expect((try ExteraPillJSONPath.resolve(root, path: "") as? [String: Any]) != nil, "Empty path resolves root")
        try self.expect((try ExteraPillJSONPath.resolve(root, path: "$") as? [String: Any]) != nil, "Dollar path resolves root")
        let array: [String] = ["first", "last"]
        try self.expect((try ExteraPillJSONPath.resolve(array, path: "$[1]") as? String) == "last", "Root array")
        for path in ["missing", "null", "data.items[2]", "data.items[-3]", "empty[0]", "empty[-1]", "flag.key", "data.items[\(Int.min)]", "data.items[\(Int.max)]"] {
            try self.expectThrows("Missing path should throw: \(path)") { _ = try ExteraPillJSONPath.resolve(root, path: path) }
        }
        for path in [".", "data.", "data..items", "data.[0]", "data.items[", "data.items[]", "data.items[01]", "data.items[+1]", "data.items[1]x", "data.items[*]", "data.items[999999999999999999999999]", #"["unterminated]"#, "data.items]", "data items"] {
            try self.expectThrows("Malformed path should throw: \(path)") { _ = try ExteraPillJSONPath.resolve(root, path: path) }
        }
        try self.expectThrows("Path length cap") { _ = try ExteraPillJSONPath.resolve(root, path: String(repeating: "x", count: 257)) }
        try self.expectThrows("Path depth cap") { _ = try ExteraPillSpec(label: "Depth", url: "https://example.com", jsonPath: Array(repeating: "x", count: 33).joined(separator: ".")).validated() }
    }

    private static func formatting() throws {
        let locale = Locale(identifier: "en_US_POSIX")
        var spec = ExteraPillSpec(label: "Test", url: "https://example.com")
        try self.expect(try ExteraPillFormatting.render("  hello\n  world  ", spec: spec, locale: locale) == "hello world", "Normalize text whitespace")
        try self.expect(try ExteraPillFormatting.render(NSNumber(value: true), spec: spec, locale: locale) == "true", "Boolean stays text")
        try self.expect(try ExteraPillFormatting.render(NSNumber(value: false), spec: spec, locale: locale) == "false", "False stays text")
        try self.expect(try ExteraPillFormatting.render(NSNumber(value: 123), spec: spec, locale: locale) == "123", "Integer stays text")
        try self.expect(try ExteraPillFormatting.render(String(repeating: "🙂", count: 200), spec: spec, locale: locale).count == 128, "Unicode output character cap")
        let invalidTextValues: [Any] = [" \n ", NSNull(), [1, 2], ["x": 1]]
        for value in invalidTextValues {
            try self.expectThrows("Non-scalar/empty text rejected") { _ = try ExteraPillFormatting.render(value, spec: spec, locale: locale) }
        }
        spec.format = .number
        spec.decimals = 2
        try self.expect(try ExteraPillFormatting.render("12.5", spec: spec, locale: locale) == "12.50", "Numeric string with fixed precision")
        spec.prefix = "$"
        spec.suffix = " USD"
        try self.expect(try ExteraPillFormatting.render(12.5, spec: spec, locale: locale) == "$12.50 USD", "Prefix and suffix")
        spec.prefix = ""
        spec.suffix = ""
        try self.expect(try ExteraPillFormatting.render(12.5, spec: spec, locale: Locale(identifier: "ru_RU")) == "12,50", "Numeric locale")
        let invalidNumbers: [Any] = [NSNumber(value: true), "NaN", "inf", Double.infinity, Double.nan, "not a number", NSNull()]
        for value in invalidNumbers {
            try self.expectThrows("Non-finite, boolean and invalid number rejected") { _ = try ExteraPillFormatting.render(value, spec: spec, locale: locale) }
        }
        spec.format = .percent
        spec.decimals = 0
        try self.expect(try ExteraPillFormatting.render(0.25, spec: spec, locale: locale) == "25%", "Percent uses fractions")
        spec.format = .bytes
        try self.expect(!(try ExteraPillFormatting.render(1024, spec: spec, locale: locale)).isEmpty, "Byte count produces output")
        for value in [-1.0, Double(Int64.max), Double.infinity] {
            try self.expectThrows("Byte count range prevents conversion traps") { _ = try ExteraPillFormatting.render(value, spec: spec, locale: locale) }
        }
    }

    private static func validation() throws {
        let spec = ExteraPillSpec(label: "  Status \n", url: " https://example.com/status ", jsonPath: " data.value ")
        let normalized = try spec.validated()
        try self.expect(normalized.label == "Status" && normalized.url == "https://example.com/status" && normalized.jsonPath == "data.value", "Trim configuration")
        for url in ["https://example.com", "http://localhost:8080/value", "https://example.com/value?token=x", "https://[::1]/value"] {
            try self.expect(ExteraPillSpec.requestURL(url) != nil, "HTTP URL accepted: \(url)")
        }
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https:///", "https://user:pass@example.com", "https://example.com/#fragment", "https://example.com/a b", "https://example.com/\n"] {
            try self.expect(ExteraPillSpec.requestURL(url) == nil, "Unsafe/malformed URL rejected: \(url)")
        }
        for refresh in [0, 60, 300, 86400] {
            var value = normalized
            value.refresh = refresh
            try self.expect(try value.validated().refresh == refresh, "Refresh boundary accepted")
        }
        for refresh in [-1, 1, 59, 86401] {
            var value = normalized
            value.refresh = refresh
            try self.expectThrows("Refresh boundary rejected") { _ = try value.validated() }
        }
        for decimals in [-1, 9] {
            var value = normalized
            value.decimals = decimals
            try self.expectThrows("Precision boundary rejected") { _ = try value.validated() }
        }
        var value = normalized
        value.label = " "
        try self.expectThrows("Empty label rejected") { _ = try value.validated() }
        value = normalized
        value.label = String(repeating: "🙂", count: 32)
        try self.expect(try value.validated().label.count == 32, "Labels count characters rather than UTF-8 bytes")
        value.label += "x"
        try self.expectThrows("Long label rejected") { _ = try value.validated() }
        value = normalized
        value.url = "https://example.com/" + String(repeating: "x", count: 2048)
        try self.expectThrows("URL cap") { _ = try value.validated() }
        value = normalized
        value.prefix = String(repeating: "x", count: 33)
        try self.expectThrows("Prefix cap") { _ = try value.validated() }
        value = normalized
        value.suffix = String(repeating: "x", count: 33)
        try self.expectThrows("Suffix cap") { _ = try value.validated() }
    }

    private static func documentsAndPersistence() throws {
        let store = ExteraPillSettings.shared
        let first = ExteraPillSpec(label: "First", url: "https://example.com/a")
        var second = ExteraPillSpec(enabled: false, label: "Second", url: "https://example.com/b", refresh: 0)
        try store.replace([first, second])
        try self.expect(store.pills == [first, second], "Order and enabled state persisted")
        let exported = try store.exportData()
        try self.expect(try ExteraPillSettings.decode(exported) == [first, second], "Export/import round-trip")
        let raw = AyuSettingsStore.shared.userDefaults.string(forKey: "extera.customHTTPPills.v1") ?? ""
        try self.expect(try ExteraPillSettings.decode(Data(raw.utf8)) == [first, second], "Persistent representation matches memory")
        try store.replace([second, first])
        second.label = "Changed"
        try store.upsert(second)
        try self.expect(store.pills == [second, first], "Upsert preserves ordered position")
        try self.expectThrows("Duplicate ids rejected atomically") { try store.replace([first, first]) }
        try self.expect(store.pills == [second, first], "Failed replacement leaves list unchanged")
        var invalid = first
        invalid.url = "file:///bad"
        try self.expectThrows("Invalid upsert rejected atomically") { try store.upsert(invalid) }
        try self.expect(store.pills == [second, first], "Failed upsert leaves list unchanged")
        var document = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        document["version"] = 2
        try self.expectThrows("Unknown document version rejected") { _ = try ExteraPillSettings.decode(JSONSerialization.data(withJSONObject: document)) }
        try self.expectThrows("Oversized file rejected before parsing") { _ = try ExteraPillSettings.decode(Data(repeating: 32, count: ExteraPillSettings.maximumFileSize + 1)) }
        try self.expectThrows("Malformed JSON rejected") { _ = try ExteraPillSettings.decode(Data("{".utf8)) }
        try self.expectThrows("Missing fields rejected") { _ = try ExteraPillSettings.decode(Data(#"{"version":1,"pills":[{}]}"#.utf8)) }
        let limit = (0 ..< 25).map { ExteraPillSpec(label: "Pill \($0)", url: "https://example.com") }
        try self.expectThrows("Pill count cap") { try store.replace(limit) }
        try store.replace([])
        try self.expect(store.pills.isEmpty, "Empty list reset")
    }

    private static func localization() throws {
        for language in ["ru", "ru-RU", "RU_ru", "ru-raw", "ru-RU-raw"] {
            try self.expect(exteraPillText(language, "English", "Русский") == "Русский", "Russian language variant: \(language)")
        }
        for language in ["en", "en-raw", "de", "", "russian"] {
            try self.expect(exteraPillText(language, "English", "Русский") == "English", "English fallback: \(language)")
        }
        try self.expect(exteraPillErrorDescription(.network, languageCode: "ru").contains("Ошибка"), "Localized runtime errors")
        try self.expect(exteraPillErrorDescription(.httpStatus(429), languageCode: "ru") == "HTTP 429", "HTTP status remains numeric")
    }
}
