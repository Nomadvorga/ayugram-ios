import Foundation

private func describe(_ suggestion: InlineMathSuggestion?) -> String? {
    return suggestion.map { "\($0.insertAt)|\($0.insertText)|\($0.value)" }
}

private final class Field {
    var text = ""
    var caret = 0
    let session: InlineMathSession
    let configuration: InlineResultsConfiguration?

    init(_ engine: InlineResultsEngine, _ configuration: InlineResultsConfiguration?) {
        self.session = InlineMathSession(engine: engine)
        self.configuration = configuration
    }

    @discardableResult
    func refresh(marked: Bool = false, active: Bool = true) -> String? {
        return describe(self.session.refresh(text: self.text, selection: NSRange(location: self.caret, length: 0), isActive: active, hasMarkedText: marked, configuration: self.configuration))
    }

    private func replace(_ range: NSRange, _ replacement: String, caret: Int) {
        self.text = (self.text as NSString).replacingCharacters(in: range, with: replacement)
        self.caret = caret
    }

    // What the text view does for one key press, the way the input panel drives the session.
    func key(_ replacement: String) {
        let range = replacement.isEmpty ? NSRange(location: self.caret - 1, length: 1) : NSRange(location: self.caret, length: 0)
        if let edit = self.session.edit(forReplacing: range, with: replacement, selection: NSRange(location: self.caret, length: 0)) {
            self.session.perform(edit) { edit in
                self.replace(edit.range, edit.replacement, caret: edit.caret)
                self.session.textDidChange()
                self.session.selectionDidChange(NSRange(location: self.caret, length: 0))
            }
        } else {
            self.replace(range, replacement, caret: range.location + replacement.utf16.count)
            self.session.textDidChange()
            self.session.selectionDidChange(NSRange(location: self.caret, length: 0))
        }
        self.refresh()
    }

    func type(_ string: String) {
        for character in string {
            self.key(String(character))
        }
    }

    func moveCaret(_ caret: Int) {
        self.caret = caret
        self.session.selectionDidChange(NSRange(location: caret, length: 0))
        self.refresh()
    }
}

func runSessionTests() {
    let store = ExchangeRatesStore(environment: ExchangeRatesStore.Environment(
        now: { 1_800_000_000_000 },
        read: { _ in nil },
        write: { _, _ in },
        download: { $0(Data("{\"data\":{\"rates\":{\"EUR\":\"0.8\",\"RUB\":\"80\"}}}".utf8)) },
        deliver: { $0() }
    ))
    var updates = 0
    let engine = InlineResultsEngine(rates: InlineRates(store: store, environment: InlineRates.Environment(
        now: { 1_800_000_000_000 },
        uptime: { 1000.0 },
        starsUsdSellRate1000: { 2000.0 },
        targetCurrency: { "" },
        currentAccount: { 1 },
        accountCurrency: { _ in "RUB" }
    ), onUpdated: { updates += 1 }))
    engine.now = winter
    engine.localZone = moscow
    engine.places = { name, _ in placeNames[name] }

    var all = InlineResultsConfiguration(timeZones: true, grouping: false)

    // Engine: carets are UTF-16 offsets.
    check("engine 2+2=", "4|4|4", describe(engine.suggestion(in: "2+2=", caret: 4, configuration: all)))
    check("engine spaced", "5| 4|4", describe(engine.suggestion(in: "2+2 = ", caret: 5, configuration: all)))
    check("engine after emoji", "14|4|4", describe(engine.suggestion(in: "😀😀 итог 2+2=", caret: 14, configuration: all)))
    check("engine caret inside a surrogate pair", nil, describe(engine.suggestion(in: "2+2=😀", caret: 5, configuration: all)))
    check("engine caret not after =", nil, describe(engine.suggestion(in: "2+2=", caret: 3, configuration: all)))
    check("engine caret out of range", nil, describe(engine.suggestion(in: "2+2=", caret: 9, configuration: all)))
    check("engine units", "9|16.09 km|16.09 km", describe(engine.suggestion(in: "10 miles=", caret: 9, configuration: all)?.withPlainSpaces))
    check("engine time zone", "10|21:00|21:00", describe(engine.suggestion(in: "18:00 utc=", caret: 10, configuration: all)))
    check("engine place", "13|10:00|10:00", describe(engine.suggestion(in: "12:00 в осло=", caret: 13, configuration: all)))
    check("engine currency before the rates arrive", nil, describe(engine.suggestion(in: "100€=", caret: 5, configuration: all)))
    check("engine rates arrival signalled", "1", "\(updates)")
    check("engine currency", "5|10000 ₽|10000 ₽", describe(engine.suggestion(in: "100€=", caret: 5, configuration: all)?.withPlainSpaces))
    all.grouping = true
    check("engine grouping", "5|10 000 ₽|10 000 ₽", describe(engine.suggestion(in: "100€=", caret: 5, configuration: all)?.withPlainSpaces))
    check("engine comma separator", "4|0,5|0,5", describe(engine.suggestion(in: "1/2=", caret: 4, configuration: InlineResultsConfiguration(decimalSeparator: ","))))
    check("engine calculator off", nil, describe(engine.suggestion(in: "2+2=", caret: 4, configuration: InlineResultsConfiguration(calculator: false))))
    check("engine time zones off", nil, describe(engine.suggestion(in: "18:00 utc=", caret: 10, configuration: InlineResultsConfiguration())))
    check("engine everything off", nil, describe(engine.suggestion(in: "2+2=", caret: 4, configuration: InlineResultsConfiguration(calculator: false, currencies: false, units: false))))
    check("engine imperial regions", "true,true,false,false", ["US", "mm", "RU", nil].map { "\(InlineResultsEngine.isImperial(regionCode: $0))" }.joined(separator: ","))
    check("engine separators", ".,", "\(InlineResultsEngine.decimalSeparator(language: "en"))\(InlineResultsEngine.decimalSeparator(language: "ru"))")

    // Every example of the settings screen gives an answer with everything switched on.
    let berlin = fullOptions(local: TimeZone(identifier: "Europe/Berlin")!)
    var examples = 0
    for group in InlineExamples.all {
        for russian in [false, true] {
            for example in group.examples(russian: russian) {
                examples += 1
                let value = MathExpression.suggestionAt(example, caret: example.unicodeScalars.count, options: berlin)?.value
                check("example(\"\(example)\") has an answer", "yes", value == nil ? "no" : "yes")
            }
        }
    }
    check("examples count", "48", "\(examples)")
    check("examples russian", "true,true,false", ["ru", "be", "en"].map { "\(InlineExamples.isRussian(language: $0))" }.joined(separator: ","))

    // Phone number -> countries of its calling code -> currency, with the app's own table.
    if let table = try? String(contentsOfFile: "submodules/TelegramUI/Resources/PhoneCountries.txt", encoding: .utf8) {
        func countries(_ phone: String) -> String {
            return InlineResultsEngine.countries(forPhone: phone, phoneCountries: table).joined(separator: ",")
        }
        check("phone RU/KZ", "RU,KZ", countries("+7 916 123-45-67"))
        check("phone US/CA", "US,CA", countries("12025550123"))
        check("phone longer code wins", "AG", countries("+1 268 555 0123"))
        check("phone DE", "DE", countries("4915112345678"))
        check("phone three digit code", "FI", countries("+358401234567"))
        check("phone unknown", "", countries("+0000"))
        check("phone empty", "", countries(""))
        check("phone currency RU", "RUB", InlineResultsEngine.localCurrency(countries: InlineResultsEngine.countries(forPhone: "79161234567", phoneCountries: table), localeCountry: "DE"))
        check("phone currency KZ by device region", "KZT", InlineResultsEngine.localCurrency(countries: InlineResultsEngine.countries(forPhone: "77011234567", phoneCountries: table), localeCountry: "KZ"))
        check("phone currency CA by device region", "CAD", InlineResultsEngine.localCurrency(countries: InlineResultsEngine.countries(forPhone: "14165550123", phoneCountries: table), localeCountry: "ca"))
    } else {
        check("PhoneCountries.txt readable (run from the repository root)", "yes", "no")
    }

    // The account currency is asked again after an invalidation.
    do {
        var currency = "RUB"
        var lookups = 0
        let rates = InlineRates(store: store, environment: InlineRates.Environment(
            now: { 1_800_000_000_000 },
            uptime: { 1000.0 },
            starsUsdSellRate1000: { 2000.0 },
            targetCurrency: { "" },
            currentAccount: { 1 },
            accountCurrency: { _ in
                lookups += 1
                return currency
            }
        ), onUpdated: {})
        let other = InlineResultsEngine(rates: rates)
        check("invalidate: first answer", "RUB", rates.localCurrency())
        currency = "KZT"
        check("invalidate: cached", "RUB", rates.localCurrency())
        other.invalidateAccountCurrency()
        check("invalidate: asked again", "KZT", rates.localCurrency())
        check("invalidate: two lookups", "2", "\(lookups)")
    }

    // Session: Space inserts, Backspace right after takes it back.
    do {
        let field = Field(engine, InlineResultsConfiguration())
        field.type("2+2")
        check("session nothing before =", nil, describe(field.session.suggestion))
        field.type("=")
        check("session suggests", "4|4|4", describe(field.session.suggestion))
        field.key(" ")
        check("session space inserts", "2+2=4", field.text)
        check("session caret after the result", "5", "\(field.caret)")
        check("session no suggestion after insert", nil, describe(field.session.suggestion))
        field.key("")
        check("session backspace undoes", "2+2=", field.text)
        check("session caret back", "4", "\(field.caret)")
        check("session quiet after undo", nil, describe(field.session.suggestion))
        field.key(" ")
        check("session space after undo is a space", "2+2= ", field.text)
        field.key("")
        check("session suggests again after an edit", "4|4|4", describe(field.session.suggestion))
        field.key("\t")
        check("session tab inserts", "2+2=4", field.text)
        field.type("!")
        field.key("")
        field.key("")
        check("session typing forgets the undo", "2+2=", field.text)
    }
    do {
        let field = Field(engine, InlineResultsConfiguration())
        field.type("2+2 =")
        check("session spaced suggestion", "5| 4|4", describe(field.session.suggestion))
        field.key(" ")
        check("session spaced insert", "2+2 = 4", field.text)
        field.moveCaret(3)
        field.moveCaret(7)
        field.key("")
        check("session moving the caret forgets the undo", "2+2 = ", field.text)
    }
    do {
        let field = Field(engine, InlineResultsConfiguration())
        field.type("2+2=")
        field.key("")
        field.type("=")
        field.key(" ")
        field.key("")
        check("session undo leaves the question", "2+2=", field.text)
        field.moveCaret(3)
        field.moveCaret(4)
        check("session suggests again after the caret returns", "4|4|4", describe(field.session.suggestion))
    }
    do {
        let field = Field(engine, InlineResultsConfiguration())
        field.text = "итого 2+2= рубля\n3*3=\nконец"
        field.moveCaret(10)
        check("session not in the middle of a line", nil, describe(field.session.suggestion))
        field.moveCaret(21)
        check("session at the end of a middle paragraph", "21|9|9", describe(field.session.suggestion))
        field.key(" ")
        check("session insert in a middle paragraph", "итого 2+2= рубля\n3*3=9\nконец", field.text)
    }
    do {
        let field = Field(engine, InlineResultsConfiguration())
        field.text = "2+2="
        field.caret = 4
        check("session while composing", nil, field.refresh(marked: true))
        check("session unfocused", nil, field.refresh(active: false))
        check("session focused", "4|4|4", field.refresh())
        check("session selection", nil, describe(field.session.refresh(text: field.text, selection: NSRange(location: 2, length: 2), isActive: true, hasMarkedText: false, configuration: field.configuration)))
        field.refresh()
        check("session space with a selection is a space", nil, field.session.edit(forReplacing: NSRange(location: 2, length: 2), with: " ", selection: NSRange(location: 2, length: 2)).map { _ in "edit" })
        field.session.dismissSuggestion()
        field.key(" ")
        check("session dismissed suggestion: space is a space", "2+2= ", field.text)
        field.session.reset()
        check("session reset", nil, describe(field.session.suggestion))

        let off = Field(engine, nil)
        off.type("2+2=")
        check("session switched off", nil, describe(off.session.suggestion))
        off.key(" ")
        check("session switched off: space is a space", "2+2= ", off.text)
    }
}

private extension InlineMathSuggestion {
    var withPlainSpaces: InlineMathSuggestion {
        return InlineMathSuggestion(insertAt: self.insertAt, insertText: self.insertText.replacingOccurrences(of: "\u{00A0}", with: " "), value: self.value.replacingOccurrences(of: "\u{00A0}", with: " "))
    }
}
