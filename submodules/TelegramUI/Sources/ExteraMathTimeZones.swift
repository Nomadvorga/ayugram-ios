import Foundation

// Native counterpart of inline/time/TimeZones.kt, Copyright exteraGram 2022–2026.
// Foundation's IANA rules resolve the offset for today's date in the source zone,
// including DST, instead of treating EST/PST and cities as fixed UTC offsets.
enum ExteraMathTimeZones {
    private static func normalize(_ value: String) -> String {
        return value.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "-", with: " ")
    }

    private static let aliases: [String: String] = {
        var result: [String: String] = [:]
        let groups: [(String, String)] = [
            ("UTC", "utc"), ("GMT", "gmt"),
            ("Europe/Moscow", "msk|мск|москва|москве|moscow|питер|питере|спб|петербург|петербурге|санкт-петербург|санкт-петербурге|st petersburg|saint petersburg"),
            ("Europe/Kaliningrad", "калининград|калининграде|kaliningrad"), ("Europe/Samara", "самара|самаре|samara"),
            ("Asia/Yekaterinburg", "екб|екатеринбург|екатеринбурге|yekaterinburg"), ("Asia/Omsk", "омск|омске|omsk"),
            ("Asia/Novosibirsk", "нск|новосибирск|новосибирске|novosibirsk"), ("Asia/Krasnoyarsk", "красноярск|красноярске|krasnoyarsk"),
            ("Asia/Irkutsk", "иркутск|иркутске|irkutsk"), ("Asia/Yakutsk", "якутск|якутске|yakutsk"),
            ("Asia/Vladivostok", "владивосток|владивостоке|vladivostok"), ("Asia/Magadan", "магадан|магадане|magadan"), ("Asia/Kamchatka", "камчатка|камчатке|kamchatka"),
            ("Europe/Kiev", "киев|киеве|київ|києві|kyiv|kiev"), ("Europe/Minsk", "минск|минске|minsk"),
            ("Asia/Almaty", "алматы|almaty|астана|астане|astana"), ("Asia/Tashkent", "ташкент|ташкенте|tashkent"),
            ("Asia/Bishkek", "бишкек|бишкеке|bishkek"), ("Asia/Dushanbe", "душанбе|dushanbe"),
            ("Asia/Tbilisi", "тбилиси|tbilisi"), ("Asia/Yerevan", "ереван|ереване|yerevan"), ("Asia/Baku", "баку|baku"),
            ("Europe/Chisinau", "кишинев|кишиневе|chisinau"), ("Europe/Riga", "рига|риге|riga"),
            ("Europe/Vilnius", "вильнюс|вильнюсе|vilnius"), ("Europe/Tallinn", "таллин|таллине|tallinn"),
            ("Europe/Helsinki", "eet|eest|хельсинки|helsinki"), ("Europe/Warsaw", "варшава|варшаве|warsaw"),
            ("Europe/Prague", "прага|праге|prague"), ("Europe/Berlin", "cet|cest|берлин|берлине|berlin"),
            ("Europe/Paris", "париж|париже|paris"), ("Europe/Rome", "рим|риме|rome"),
            ("Europe/Madrid", "мадрид|мадриде|madrid|барселона|барселоне|barcelona"), ("Europe/Amsterdam", "амстердам|амстердаме|amsterdam"),
            ("Europe/London", "bst|лондон|лондоне|london"), ("Europe/Lisbon", "wet|west|лиссабон|лиссабоне|lisbon"),
            ("Europe/Istanbul", "стамбул|стамбуле|istanbul|анталья|анталье|antalya"),
            ("Asia/Jerusalem", "тель-авив|тель-авиве|tel aviv|иерусалим|иерусалиме|jerusalem"),
            ("Asia/Dubai", "дубай|дубае|dubai"), ("Africa/Cairo", "каир|каире|cairo"),
            ("Asia/Kolkata", "ist|дели|delhi|new delhi|мумбаи|mumbai"), ("Asia/Bangkok", "бангкок|бангкоке|bangkok|пхукет|пхукете|phuket"),
            ("Asia/Makassar", "бали|bali"), ("Asia/Singapore", "sgt|сингапур|сингапуре|singapore"),
            ("Asia/Hong_Kong", "hkt|гонконг|гонконге|hong kong"), ("Asia/Shanghai", "пекин|пекине|beijing|шанхай|шанхае|shanghai"),
            ("Asia/Seoul", "kst|сеул|сеуле|seoul"), ("Asia/Tokyo", "jst|токио|tokyo"),
            ("Australia/Perth", "awst|перт|перте|perth"), ("Australia/Sydney", "aest|aedt|сидней|сиднее|sydney"),
            ("Australia/Melbourne", "мельбурн|мельбурне|melbourne"), ("Pacific/Auckland", "nzst|nzdt|окленд|окленде|auckland"),
            ("America/New_York", "est|edt|нью-йорк|нью-йорке|new york|nyc|вашингтон|вашингтоне|washington|майами|miami"),
            ("America/Toronto", "торонто|toronto"), ("America/Chicago", "cst|cdt|чикаго|chicago"),
            ("America/Denver", "mst|mdt|денвер|денвере|denver"),
            ("America/Los_Angeles", "pst|pdt|лос-анджелес|лос-анджелесе|los angeles|сан-франциско|san francisco|сиэтл|сиэтле|seattle"),
            ("America/Vancouver", "ванкувер|ванкувере|vancouver"), ("America/Anchorage", "akst|akdt|анкоридж|анкоридже|anchorage"),
            ("Pacific/Honolulu", "hst|гонолулу|honolulu"), ("America/Mexico_City", "мехико|mexico city"),
            ("America/Sao_Paulo", "сан-паулу|sao paulo"), ("America/Argentina/Buenos_Aires", "буэнос-айрес|буэнос-айресе|buenos aires")
        ]
        for (zone, words) in groups {
            for word in words.split(separator: "|") { result[ExteraMathTimeZones.normalize(String(word))] = zone }
        }
        return result
    }()

    private static let identifiers: [String: String] = Dictionary(
        TimeZone.knownTimeZoneIdentifiers.map { ($0.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    private static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) else { return nil }
        return (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : (value as NSString).substring(with: match.range(at: $0)) }
    }

    private static func zone(_ words: ArraySlice<String>) -> TimeZone? {
        let text = words.joined(separator: " ")
        let name = self.normalize(text)
        if let identifier = self.aliases[name] { return TimeZone(identifier: identifier) }
        // IANA names are also accepted without a place service/network request.
        if let identifier = self.identifiers[text] { return TimeZone(identifier: identifier) }
        guard let match = self.captures(#"^(utc|gmt|msk|мск) ?([+-]) ?([0-9]{1,2})(?::?([0-9]{2}))?$"#, text),
              let hours = Int(match[3]), let minutes = Int(match[4].isEmpty ? "0" : match[4]), hours <= 18, minutes < 60 else { return nil }
        let base = ["msk", "мск"].contains(match[1]) ? 180 : 0
        let total = base + (match[2] == "-" ? -1 : 1) * (hours * 60 + minutes)
        guard abs(total) <= 18 * 60 else { return nil }
        return TimeZone(secondsFromGMT: total * 60)
    }

    static func convert(_ expression: String, local: TimeZone, now: Date) -> String? {
        guard expression.utf16.count <= 512 else { return nil }
        var words = expression.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "−", with: "-").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, words.count <= 20 else { return nil }
        var target: TimeZone?
        var source: TimeZone?
        for count in stride(from: 3, through: 1, by: -1) {
            let marker = words.count - count - 1
            if marker >= 1, ["to", "in", "в", "во", "на"].contains(words[marker]), let zone = self.zone(words[(marker + 1)...]) {
                target = zone
                words.removeLast(count + 1)
                break
            }
        }
        for count in stride(from: 3, through: 1, by: -1) {
            if words.count > count, let zone = self.zone(words.suffix(count)) {
                source = zone
                words.removeLast(count)
                if words.last == "по" { words.removeLast() }
                break
            }
        }
        if let last = words.last, ["am", "pm", "a.m.", "p.m."].contains(last), words.count == 2 {
            words = [words[0] + last]
        }
        // Whole-line parsing prevents prose, bot queries and commands stealing
        // another input context surface. This intentionally stays stricter than Android.
        guard words.count == 1, let time = words.first else { return nil }
        if ["now", "сейчас"].contains(time) {
            guard let target, source == nil else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = target
            return self.format(hour: calendar.component(.hour, from: now), minute: calendar.component(.minute, from: now), meridiem: false)
        }
        guard let match = self.captures(#"^([0-9]{1,2})(?:[:.]([0-9]{2}))?(am|pm|a\.m\.|p\.m\.)?$"#, time), let rawHour = Int(match[1]),
              let minute = Int(match[2].isEmpty ? "0" : match[2]), minute < 60 else { return nil }
        let meridiem = !match[3].isEmpty
        guard source != nil || target != nil || meridiem, !match[2].isEmpty || meridiem || source != nil else { return nil }
        let hour: Int
        if meridiem {
            guard (1...12).contains(rawHour) else { return nil }
            hour = rawHour % 12 + (match[3].hasPrefix("p") ? 12 : 0)
        } else {
            guard rawHour <= 23 else { return nil }
            hour = rawHour
        }
        if source == nil && target == nil { return self.format(hour: hour, minute: minute, meridiem: false) }
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = source ?? local
        // .nextTimePreservingSmallerComponents matches java.time's forward
        // adjustment through a DST gap; .first selects the earlier overlap.
        let startOfDay = sourceCalendar.startOfDay(for: now)
        guard let date = sourceCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay, matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first, direction: .forward) else { return nil }
        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = target ?? local
        let targetHour = targetCalendar.component(.hour, from: date)
        let targetMinute = targetCalendar.component(.minute, from: date)
        let sourceDate = sourceCalendar.dateComponents([.year, .month, .day], from: date)
        let targetDate = targetCalendar.dateComponents([.year, .month, .day], from: date)
        var neutral = Calendar(identifier: .gregorian)
        neutral.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let sourceDay = neutral.date(from: sourceDate), let targetDay = neutral.date(from: targetDate),
              let shift = neutral.dateComponents([.day], from: sourceDay, to: targetDay).day else { return nil }
        guard shift != 0 || targetHour != hour || targetMinute != minute else { return nil }
        let value = self.format(hour: targetHour, minute: targetMinute, meridiem: meridiem)
        return value + (shift == 0 ? "" : " (" + (shift > 0 ? "+" : "") + String(shift) + ")")
    }

    private static func format(hour: Int, minute: Int, meridiem: Bool) -> String {
        let minutes = String(format: "%02d", minute)
        if meridiem { return String((hour + 11) % 12 + 1) + ":" + minutes + (hour < 12 ? " am" : " pm") }
        return String(format: "%02d", hour) + ":" + minutes
    }
}
