// Ported from exteraGram for Android (com.exteragram.messenger.inline.InlineZonePlaces), GPL v3 or later, © exteraGram.

import Foundation

// City and country names of the system's time zone database, in English, Russian and the app language.
final class InlineZonePlaces {
    private static let minNameLength = 3

    static let shared = InlineZonePlaces()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.ayugram.inline.zone-places", qos: .utility)
    private var index: [String: String]?
    private var indexLocale: String?
    private var building = false

    // Answers from the index built so far; the first call and a language change only start a build.
    func lookup(_ name: String, locale: String) -> String? {
        self.lock.lock()
        let built = self.index
        let stale = built == nil || self.indexLocale != locale
        self.lock.unlock()
        if stale {
            self.prepare(locale: locale)
        }
        return built?[name]
    }

    func prepare(locale: String) {
        self.lock.lock()
        if (self.index != nil && self.indexLocale == locale) || self.building {
            self.lock.unlock()
            return
        }
        self.building = true
        self.lock.unlock()

        self.queue.async {
            let built = InlineZonePlaces.build(locale: locale)
            self.lock.lock()
            self.indexLocale = locale
            self.index = built
            self.building = false
            self.lock.unlock()
        }
    }

    static func build(locale: String?) -> [String: String] {
        var result: [String: String] = [:]
        var locales = ["en", "ru"]
        if let locale, !locale.isEmpty, !locales.contains(locale) {
            locales.append(locale)
        }
        let zones = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }.compactMap { id in
            TimeZone(identifier: id).map { (id, $0) }
        }
        let countries = self.primaryZones(zones)
        let now = Date()
        for identifier in locales {
            let locale = Locale(identifier: identifier)
            let formatter = DateFormatter()
            formatter.locale = locale
            // The exemplar city of the zone.
            formatter.dateFormat = "VVV"
            for (id, zone) in zones {
                formatter.timeZone = zone
                self.put(&result, formatter.string(from: now), id)
            }
            for (region, id) in countries {
                if let country = locale.localizedString(forRegionCode: region) {
                    self.put(&result, country, id)
                }
            }
        }
        // Apple's region names say "China mainland" where Android's say "China".
        if let china = countries.first(where: { $0.0 == "CN" })?.1 {
            self.put(&result, "China", china)
            self.put(&result, "Китай", china)
        }
        return result
    }

    // The one zone that stands for a whole country: "Norway Time" is Europe/Oslo. Countries whose zones are
    // all named after cities (Russia, the United States) get none.
    private static func primaryZones(_ zones: [(String, TimeZone)]) -> [(String, String)] {
        let english = Locale(identifier: "en")
        let formatter = DateFormatter()
        formatter.locale = english
        formatter.dateFormat = "VVVV"
        let now = Date()
        var named: [String: [(String, TimeZone)]] = [:]
        for (id, zone) in zones {
            formatter.timeZone = zone
            named[formatter.string(from: now), default: []].append((id, zone))
        }
        var result: [(String, String)] = []
        for region in NSLocale.isoCountryCodes.sorted() {
            guard let country = english.localizedString(forRegionCode: region), let candidates = named["\(country) Time"], let first = candidates.first else {
                continue
            }
            // The system list also has old names of the same zone (Asia/Chongqing for Asia/Shanghai), which
            // carry the country name too. Zones that really differ leave the country without an answer.
            let same = candidates.allSatisfy {
                $0.1.secondsFromGMT(for: now) == first.1.secondsFromGMT(for: now) && $0.1.nextDaylightSavingTimeTransition(after: now) == first.1.nextDaylightSavingTimeTransition(after: now)
            }
            if !same {
                continue
            }
            formatter.dateFormat = "VVV"
            formatter.timeZone = first.1
            let city = formatter.string(from: now).replacingOccurrences(of: " ", with: "_")
            formatter.dateFormat = "VVVV"
            let id = candidates.first(where: { $0.0.hasSuffix("/" + city) })?.0 ?? first.0
            result.append((region, id))
        }
        return result
    }

    private static func put(_ index: inout [String: String], _ name: String, _ id: String) {
        let key = TimeZones.normalize(name)
        if key.utf16.count < self.minNameLength {
            return
        }
        if index[key] == nil {
            index[key] = id
        }
        if !key.unicodeScalars.contains(where: { $0.value >= 0x430 && $0.value <= 0x44F }) {
            var plain = String.UnicodeScalarView()
            plain.append(contentsOf: key.decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark })
            let stripped = String(plain)
            if index[stripped] == nil {
                index[stripped] = id
            }
        }
    }
}
