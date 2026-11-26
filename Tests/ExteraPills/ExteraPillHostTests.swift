import Foundation

// Only the preferences adapter is replaced. Compile the production ExteraPillSettings.swift and
// ExteraPillStrings.swift and ExteraPillStackSettings.swift alongside this file: no copied model.
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
        try self.stackPersistence()
        try self.stackOrdering()
        try self.providers()
        try self.requestScopes()
        try self.entryTime()
        try self.portableStackDocument()
        print("PASS: \(self.assertions) production pill path/format/validation/import/persistence/localization/stack/provider assertions")
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

    private static func stackPersistence() throws {
        let defaults = AyuSettingsStore.shared.userDefaults
        let store = ExteraPillStackSettings(userDefaults: defaults)
        // Literal old v1 document: this fixture must remain readable without stack/provider fields.
        let fixture = Data(#"{"version":1,"pills":[{"id":"00000000-0000-0000-0000-000000000031","enabled":true,"label":"Legacy","url":"https://example.com/value?token=private","jsonPath":"data.value","refresh":300,"format":"number","decimals":2,"prefix":"","suffix":" USD"}]}"#.utf8)
        let custom = try ExteraPillSettings.decode(fixture)
        let id = ExteraPillStackLayout.customId(custom[0].id)
        let initial = store.layout.normalized(custom: custom)
        try self.expect(initial.visible.isEmpty && initial.infiniteScrolling, "Reference default: all hidden, infinite enabled")
        try self.expect(initial.hidden == ExteraBuiltinPill.allCases.map { $0.id } + [id], "Exact seven-item inventory followed by hidden legacy custom IDs")
        try self.expect(!store.allowed("weather", account: 1) && !store.allowed("rates", account: 1) && !store.allowsCustom(custom[0], account: 1), "Migration never grants remote requests")
        store.update(custom: custom) { state in
            state.setVisible("builtin.proxy", true); state.setVisible(id, true)
            state.infiniteScrolling = false; state.selected = id
        }
        let reopened = ExteraPillStackSettings(userDefaults: defaults)
        try self.expect(reopened.layout == store.layout, "Reopening preserves selection, order, hidden list and infinite flag")
        try self.expect(reopened.layout.renderedIds(custom: custom) == ["builtin.proxy", id], "Renderer uses persisted order")
        var disabled = custom; disabled[0].enabled = false
        try self.expect(reopened.layout.renderedIds(custom: disabled) == ["builtin.proxy"], "Disabled HTTP widget never enters renderer")
        try self.expect(reopened.layout.visible.contains(id), "HTTP disabled state does not erase stack position")
        store.allow("weather", account: 1, value: true); store.allow("rates", account: 2, value: true)
        store.allowCustom(custom[0], account: 1, value: true)
        try self.expect(reopened.allowed("weather", account: 1) && !reopened.allowed("weather", account: 2), "Weather consent is per-account and persisted")
        try self.expect(!reopened.allowsWeather(source: "izweatherbot", account: 1), "Generic weather grant cannot silently approve a new bot")
        store.allowWeather(source: "izweatherbot", account: 1, value: true)
        try self.expect(reopened.allowsWeather(source: "izweatherbot", account: 1) && !reopened.allowsWeather(source: "otherbot", account: 1) && !reopened.allowsWeather(source: "izweatherbot", account: 2), "Weather grant binds bot source and account")
        reopened.allowWeather(source: "izweatherbot", account: 1, value: false)
        try self.expect(!store.allowsWeather(source: "izweatherbot", account: 1), "Weather revocation removes source grant")
        try self.expect(!reopened.allowed("rates", account: 1) && reopened.allowed("rates", account: 2), "Rates consent cannot bleed across accounts")
        var changedEndpoint = custom[0]; changedEndpoint.url = "https://other.example/value"
        try self.expect(!reopened.allowsCustom(changedEndpoint, account: 1), "Same UUID with replaced URL requires fresh consent")
        try self.expect(reopened.allowsCustom(custom[0], account: 1) && !reopened.allowsCustom(custom[0], account: 2), "Custom consent binds URL and account")
        reopened.allowCustom(custom[0], account: 1, value: false)
        try self.expect(!store.allowsCustom(custom[0], account: 1), "Explicit revocation persists")
        store.setCurrency("EUR", account: 1); store.setCurrency("RUB", account: 2); store.setCurrency("bad!", account: 1)
        try self.expect(reopened.currency(account: 1) == "EUR" && reopened.currency(account: 2) == "RUB", "Independent target currencies; malformed code rejected")
        try ExteraPillSettings.shared.replace(custom)
        let oldDocument = try ExteraPillSettings.shared.exportData()
        try self.expect(try ExteraPillSettings.decode(oldDocument) == custom, "Stack updates do not change HTTP import/export schema or credentials")
        store.update(custom: []) { _ in }
        try self.expect(!store.layout.visible.contains(id) && store.layout.selected == nil, "Deleted custom IDs and selection are sanitized")
        store.update(custom: custom) { _ in }
        try self.expect(!store.layout.visible.contains(id) && store.layout.hidden.contains(id), "Reimported custom item remains hidden")
    }

    private static func stackOrdering() throws {
        var state = ExteraPillStackLayout()
        let original = state
        state.move("stale", visible: true, before: nil); state.setVisible("stale", true)
        try self.expect(state == original, "Stale identity is a no-op")
        state.setVisible("builtin.weather", true); state.setVisible("builtin.proxy", true); state.setVisible("builtin.storage", true)
        state.move("builtin.storage", visible: true, before: "builtin.weather")
        try self.expect(state.visible == ["builtin.storage", "builtin.weather", "builtin.proxy"], "Upward identity move")
        state.move("builtin.storage", visible: true, before: nil)
        try self.expect(state.visible == ["builtin.weather", "builtin.proxy", "builtin.storage"], "Move to end")
        state.move("builtin.weather", visible: true, before: "builtin.storage")
        try self.expect(state.visible == ["builtin.proxy", "builtin.weather", "builtin.storage"], "Downward insertion has no index shift error")
        state.move("builtin.btc", visible: true, before: "builtin.weather")
        try self.expect(state.visible == ["builtin.proxy", "builtin.btc", "builtin.weather", "builtin.storage"] && !state.hidden.contains("builtin.btc"), "Cross-section move toggles visibility")
        state.selected = "builtin.btc"; state.setVisible("builtin.btc", false)
        try self.expect(state.selected == nil && state.hidden.last == "builtin.btc", "Hiding selection clears it and appends to hidden order")
        let before = state
        state.move("builtin.proxy", visible: true, before: "stale")
        try self.expect(state == before, "Stale target cannot erase or relocate item")
        state.visible += ["builtin.proxy", "unknown"]
        state.hidden += ["builtin.proxy", "builtin.weather"]
        state = state.normalized(custom: [])
        try self.expect(Set(state.visible + state.hidden).count == 7 && state.visible.count + state.hidden.count == 7, "Corrupt/old layout normalization deduplicates and preserves complete inventory")
        let ids = state.renderedIds(custom: [])
        try self.expect(state.next(from: ids.last, direction: 1, ids: ids) == ids.first, "Infinite wraps last to first")
        try self.expect(state.next(from: ids.first, direction: -1, ids: ids) == ids.last, "Infinite wraps first to last")
        state.infiniteScrolling = false
        try self.expect(state.next(from: ids.last, direction: 1, ids: ids) == ids.last, "Finite stops at last")
        try self.expect(state.next(from: ids.first, direction: -1, ids: ids) == ids.first, "Finite stops at first")
        try self.expect(state.next(from: "deleted", direction: 1, ids: ids) == ids.first, "Missing current selection falls back")
        try self.expect(state.next(from: nil, direction: 1, ids: []) == nil, "Empty stack is inert")
        try self.expect(state.next(from: "one", direction: -1, ids: ["one"]) == "one", "Single-item finite stack is stable")
    }

    private static func providers() throws {
        var gate = ExteraPillProviderGeneration()
        let weather = gate.begin("builtin.weather")
        try self.expect(gate.accepts(weather), "Active provider completion is accepted")
        let btc = gate.begin("builtin.btc")
        try self.expect(!gate.accepts(weather) && gate.accepts(btc), "Provider order switch rejects previous completion")
        let weatherAgain = gate.begin("builtin.weather")
        try self.expect(!gate.accepts(weather) && !gate.accepts(btc) && gate.accepts(weatherAgain), "A-B-A cannot accept an old A response")
        gate.cancel()
        try self.expect(!gate.accepts(weatherAgain), "Hide/background/navigation cancellation rejects completion")
        let resumed = gate.begin("builtin.weather")
        try self.expect(gate.accepts(resumed) && !gate.accepts(weatherAgain), "Resumption only accepts new generation")
        let rates = Data(#"{"data":{"currency":"USD","rates":{"USD":"1","TON":"0.5","BTC":"0.00002","EUR":"0.9","RUB":"90"}}}"#.utf8)
        let locale = Locale(identifier: "en_US_POSIX")
        try self.expect(try ExteraPillExchangeRate.value(data: rates, base: "TON", target: "EUR", locale: locale) == "1.8 EUR", "GRAM uses real TON cross-rate, never hardcoded balance")
        try self.expect(try ExteraPillExchangeRate.value(data: rates, base: "BTC", target: "USD", locale: locale) == "50,000 USD", "BTC reciprocal units per USD")
        try self.expect(try ExteraPillExchangeRate.value(data: rates, base: "USD", target: "RUB", locale: locale) == "90 RUB", "USD respects selected target")
        try self.expectThrows("Unsupported target produces unavailable") { _ = try ExteraPillExchangeRate.value(data: rates, base: "TON", target: "ZZZ") }
        for fixture in [#"{"data":{"currency":"EUR","rates":{"USD":"1"}}}"#, #"{"data":{"currency":"USD","rates":{"USD":"1","TON":"0"}}}"#, #"{"data":{"currency":"USD","rates":{"USD":"1","TON":"NaN"}}}"#, #"{"data":{"currency":"USD","rates":{"USD":"1","TON":"-1"}}}"#, "{"] {
            try self.expectThrows("Invalid remote data never becomes a price") { _ = try ExteraPillExchangeRate.value(data: Data(fixture.utf8), base: "TON", target: "USD") }
        }
        try self.expectThrows("Provider response cap before parsing") { _ = try ExteraPillExchangeRate.value(data: Data(repeating: 32, count: 512 * 1024 + 1), base: "TON", target: "USD") }
    }

    private static func requestScopes() throws {
        let selected = ExteraPillSpec(label: "Selected", url: "https://example.com/a")
        let hidden = ExteraPillSpec(label: "Hidden", url: "https://example.com/b")
        var leases = ExteraPillRequestLeases()
        try self.expect(leases.isEmpty && !leases.permits(selected), "No visible host means no HTTP requests")
        let search = leases.acquire(approved: [selected])
        try self.expect(leases.permits(selected) && !leases.permits(hidden), "Search lease cannot request hidden endpoints")
        var disabled = selected; disabled.enabled = false
        try self.expect(!leases.permits(disabled), "Disabling a configuration invalidates its previous search lease")
        var reformatted = selected; reformatted.jsonPath = "new.value"
        try self.expect(!leases.permits(reformatted), "Configuration edits invalidate the exact approved snapshot")
        var replacement = selected; replacement.url = hidden.url
        try self.expect(!leases.permits(replacement), "Same UUID with imported replacement URL is outside an existing lease")
        let otherHost = leases.acquire(approved: [hidden])
        try self.expect(leases.permits(selected) && leases.permits(hidden), "Independent hosts observe their own selected configurations")
        leases.release(search)
        try self.expect(!leases.permits(selected) && leases.permits(hidden), "Closing one host narrows scope without stopping the other")
        let dashboard = leases.acquire(approved: nil)
        try self.expect(leases.permits(selected) && leases.permits(replacement), "Explicit HTTP dashboard retains live configuration behavior")
        leases.release(dashboard)
        try self.expect(!leases.permits(selected) && !leases.permits(replacement) && leases.permits(hidden), "Closing dashboard cancels work that surviving search hosts did not approve")
        leases.release(otherHost)
        try self.expect(leases.isEmpty && !leases.permits(hidden), "Last host removal cancels all scopes")
        let empty = leases.acquire(approved: [])
        try self.expect(!leases.permits(selected) && !leases.permits(hidden), "Empty search selection does not mean all endpoints")
        leases.release(empty)
        let minimal = try JSONDecoder().decode(ExteraPillStackLayout.self, from: Data(#"{"visible":["builtin.proxy"]}"#.utf8))
        try self.expect(minimal.infiniteScrolling && minimal.normalized(custom: []).visible == ["builtin.proxy"], "Missing optional layout fields migrate without erasing order")
        let defaults = AyuSettingsStore.shared.userDefaults
        defaults.set(Data("{".utf8), forKey: ExteraPillStackSettings.key)
        try self.expect(ExteraPillStackSettings(userDefaults: defaults).layout == ExteraPillStackLayout(), "Malformed layout safely defaults without granting visibility")
        defaults.removeObject(forKey: ExteraPillStackSettings.key)
    }

    private static func entryTime() throws {
        let defaults = AyuSettingsStore.shared.userDefaults
        let store = ExteraPillStackSettings(userDefaults: defaults)
        try self.expect(!store.entryTimeAutoRefresh(account: 501) && !store.entryTimeAutoRefresh(account: 502), "Entry Time auto-refresh defaults off in both accounts")
        store.setEntryTimeAutoRefresh(true, account: 501)
        try self.expect(ExteraPillStackSettings(userDefaults: defaults).entryTimeAutoRefresh(account: 501), "Entry Time account preference survives store recreation")
        try self.expect(!store.entryTimeAutoRefresh(account: 502), "Entry Time preference never leaks across accounts")
        store.setEntryTimeAutoRefresh(false, account: 501)
        try self.expect(!store.entryTimeAutoRefresh(account: 501), "Entry Time periodic refresh can be disabled")
        try self.expect(ExteraPillEntryStatus.online(until: 101).presentation(serverNow: 100) == .online, "Only an unexpired server Online variant shows Online")
        try self.expect(ExteraPillEntryStatus.online(until: 100).presentation(serverNow: 100) == .lastSeen(100), "Online expiry boundary uses the server timestamp")
        try self.expect(ExteraPillEntryStatus.online(until: 99).presentation(serverNow: 100) == .lastSeen(99), "Expired Online displays its actual timestamp")
        try self.expect(ExteraPillEntryStatus.offline(at: 101).presentation(serverNow: 100) == .lastSeen(101), "Future Offline is never converted into Online by a clock comparison")
        for timestamp in [Int32(0), Int32(-1)] {
            try self.expect(ExteraPillEntryStatus.offline(at: timestamp).presentation(serverNow: 100) == .longAgo, "Missing last seen never substitutes the local current time")
            try self.expect(ExteraPillEntryStatus.online(until: timestamp).presentation(serverNow: 100) == .longAgo, "Nonpositive expired Online uses APK fallback")
        }
        try self.expect(ExteraPillEntryStatus.longAgo.presentation(serverNow: 100) == .longAgo, "Coarse/hidden/missing status matches APK long-ago fallback")
    }

    private static func portableStackDocument() throws {
        let custom = [ExteraPillSpec(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, label: "Private endpoint", url: "https://example.com/?token=never-export")]
        var layout = ExteraPillStackLayout().normalized(custom: custom)
        layout.setVisible("builtin.entryTime", true)
        layout.setVisible(ExteraPillStackLayout.customId(custom[0].id), true)
        layout.selected = "builtin.entryTime"; layout.infiniteScrolling = false
        let store = ExteraPillStackSettings(userDefaults: AyuSettingsStore.shared.userDefaults)
        store.allowCustom(custom[0], account: 501, value: true)
        store.allowWeather(source: "source_bot", account: 501, value: true)
        let previousLayout = store.layout
        let data = try ExteraPillStackDocument.encode(layout, custom: custom)
        try self.expect(try ExteraPillStackDocument.decode(data, custom: custom) == layout, "Portable layout preserves order, visibility, selection and finite mode exactly")
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["token", "example.com", "source_bot", "weatherSource", "allow", "currency", "entryTimeAutoRefresh", "501"] {
            try self.expect(!json.contains(forbidden), "Portable layout excludes endpoint secrets, source grants and account settings: \(forbidden)")
        }
        try self.expect(store.layout == previousLayout && store.allowsCustom(custom[0], account: 501) && store.allowsWeather(source: "source_bot", account: 501), "Pure document encode/decode never changes live preferences or grants")
        try self.expectThrows("Custom UUIDs must be resolved against incoming HTTP configuration") { _ = try ExteraPillStackDocument.decode(data, custom: []) }
        let fixture = #"{"version":1,"layout":{"visible":[],"hidden":["builtin.weather","builtin.gram","builtin.btc","builtin.usd","builtin.storage","builtin.proxy","builtin.entryTime"],"infiniteScrolling":true}}"#
        try self.expect(try ExteraPillStackDocument.decode(Data(fixture.utf8), custom: []) == ExteraPillStackLayout(), "Literal portable v1 defaults decode without normalization")
        let nullSelection = fixture.replacingOccurrences(of: "\"infiniteScrolling\":true", with: "\"infiniteScrolling\":true,\"selected\":null")
        try self.expect(try ExteraPillStackDocument.decode(Data(nullSelection.utf8), custom: []) == ExteraPillStackLayout(), "Explicit null selection is portable")
        let malformed = [
            fixture.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            fixture.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
            fixture.replacingOccurrences(of: "\"version\":1,", with: ""),
            fixture.replacingOccurrences(of: "\"layout\":", with: "\"allow\":true,\"layout\":"),
            fixture.replacingOccurrences(of: "\"visible\":[]", with: "\"visible\":[],\"weatherSource\":\"injected\""),
            fixture.replacingOccurrences(of: "\"visible\":[]", with: "\"visible\":null"),
            fixture.replacingOccurrences(of: "\"visible\":[]", with: "\"visible\":false"),
            fixture.replacingOccurrences(of: "\"visible\":[]", with: "\"visible\":[\"builtin.weather\"]"),
            fixture.replacingOccurrences(of: "\"builtin.entryTime\"", with: "\"builtin.weather\""),
            fixture.replacingOccurrences(of: "\"builtin.entryTime\"", with: "\"builtin.unknown\""),
            fixture.replacingOccurrences(of: ",\"builtin.entryTime\"", with: ""),
            fixture.replacingOccurrences(of: "\"infiniteScrolling\":true", with: "\"infiniteScrolling\":1"),
            fixture.replacingOccurrences(of: "\"infiniteScrolling\":true", with: "\"infiniteScrolling\":null"),
            fixture.replacingOccurrences(of: "\"infiniteScrolling\":true", with: "\"selected\":\"builtin.weather\""),
            fixture.replacingOccurrences(of: "\"infiniteScrolling\":true", with: "\"infiniteScrolling\":true,\"selected\":\"builtin.weather\""),
            #"{"version":1,"layout":{"visible":[],"hidden":null,"infiniteScrolling":true}}"#,
            "[]", "null", "{"
        ]
        for invalid in malformed {
            try self.expectThrows("Malformed/unknown/duplicate/incomplete portable layout is rejected") { _ = try ExteraPillStackDocument.decode(Data(invalid.utf8), custom: []) }
        }
        try self.expectThrows("Portable document size cap") { _ = try ExteraPillStackDocument.decode(Data(repeating: 32, count: ExteraPillStackDocument.maximumFileSize + 1), custom: []) }
        var invalid = layout; invalid.selected = "builtin.proxy"
        try self.expectThrows("Encode also rejects hidden selection") { _ = try ExteraPillStackDocument.encode(invalid, custom: custom) }
        try self.expectThrows("Duplicate incoming custom UUID cannot masquerade as a complete inventory") { _ = try ExteraPillStackDocument.validate(layout, custom: custom + custom) }
        try self.expect(store.layout == previousLayout && store.allowsCustom(custom[0], account: 501), "Failed document validation is transactional and retains remote grants")
    }
}
