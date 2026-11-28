// Ported from exteraGram for Android (com.exteragram.messenger.inline.time), GPL v3 or later, © exteraGram.

import Foundation

struct TimeZoneOptions {
    var local: TimeZone
    var now: Date? = nil
    // Zone identifier for a normalized place name that the built-in table does not know.
    var places: ((String) -> String?)? = nil
}

enum TimeZones {
    private static let maxScan = 64
    private static let maxZoneWords = 3
    private static let moscowOffsetHours = 3
    private static let maxOffsetHours = 18

    private static let targetMarkers: Set<String> = ["в", "во", "на", "to", "in"]
    private static let sourceMarkers: Set<String> = ["по"]
    private static let nowWords: Set<String> = ["сейчас", "now"]
    private static let meridiems: [String] = ["am", "pm", "a.m.", "p.m."]
    private static let offsetPrefixes: [String] = ["utc", "gmt", "msk", "мск"]

    private static let caseEndings: [(String, [String])] = [
        ("ии", ["ия"]),
        ("ах", ["ы", "и"]),
        ("ях", ["и"]),
        ("е", ["", "а", "я", "ь", "й"]),
        ("и", ["ь"])
    ]

    private static let zones: [String: String] = {
        var zones: [String: String] = [:]
        func add(_ zone: String, _ names: String...) {
            for name in names {
                zones[normalize(name)] = zone
            }
        }

        add("UTC", "utc")
        add("GMT", "gmt")
        add("Europe/Moscow", "msk", "мск", "москва", "москве", "moscow", "питер", "питере", "спб", "петербург", "петербурге",
            "санкт-петербург", "санкт-петербурге", "st petersburg", "saint petersburg")
        add("Europe/Kaliningrad", "калининград", "калининграде", "kaliningrad")
        add("Europe/Samara", "самара", "самаре", "samara")
        add("Asia/Yekaterinburg", "екб", "екатеринбург", "екатеринбурге", "yekaterinburg")
        add("Asia/Omsk", "омск", "омске", "omsk")
        add("Asia/Novosibirsk", "нск", "новосибирск", "новосибирске", "novosibirsk")
        add("Asia/Krasnoyarsk", "красноярск", "красноярске", "krasnoyarsk")
        add("Asia/Irkutsk", "иркутск", "иркутске", "irkutsk")
        add("Asia/Yakutsk", "якутск", "якутске", "yakutsk")
        add("Asia/Vladivostok", "владивосток", "владивостоке", "vladivostok")
        add("Asia/Magadan", "магадан", "магадане", "magadan")
        add("Asia/Kamchatka", "камчатка", "камчатке", "kamchatka")
        add("Europe/Kiev", "киев", "киеве", "київ", "києві", "kyiv", "kiev")
        add("Europe/Minsk", "минск", "минске", "minsk")
        add("Asia/Almaty", "алматы", "almaty", "астана", "астане", "astana")
        add("Asia/Tashkent", "ташкент", "ташкенте", "tashkent")
        add("Asia/Bishkek", "бишкек", "бишкеке", "bishkek")
        add("Asia/Dushanbe", "душанбе", "dushanbe")
        add("Asia/Tbilisi", "тбилиси", "tbilisi")
        add("Asia/Yerevan", "ереван", "ереване", "yerevan")
        add("Asia/Baku", "баку", "baku")
        add("Europe/Chisinau", "кишинев", "кишиневе", "chisinau")
        add("Europe/Riga", "рига", "риге", "riga")
        add("Europe/Vilnius", "вильнюс", "вильнюсе", "vilnius")
        add("Europe/Tallinn", "таллин", "таллине", "tallinn")
        add("Europe/Helsinki", "eet", "eest", "хельсинки", "helsinki")
        add("Europe/Warsaw", "варшава", "варшаве", "warsaw")
        add("Europe/Prague", "прага", "праге", "prague")
        add("Europe/Berlin", "cet", "cest", "берлин", "берлине", "berlin")
        add("Europe/Paris", "париж", "париже", "paris")
        add("Europe/Rome", "рим", "риме", "rome")
        add("Europe/Madrid", "мадрид", "мадриде", "madrid", "барселона", "барселоне", "barcelona")
        add("Europe/Amsterdam", "амстердам", "амстердаме", "amsterdam")
        add("Europe/London", "bst", "лондон", "лондоне", "london")
        add("Europe/Lisbon", "wet", "west", "лиссабон", "лиссабоне", "lisbon")
        add("Europe/Istanbul", "стамбул", "стамбуле", "istanbul", "анталья", "анталье", "antalya")
        add("Asia/Jerusalem", "тель-авив", "тель-авиве", "tel aviv", "иерусалим", "иерусалиме", "jerusalem")
        add("Asia/Dubai", "дубай", "дубае", "dubai")
        add("Africa/Cairo", "каир", "каире", "cairo")
        add("Asia/Kolkata", "ist", "дели", "delhi", "new delhi", "мумбаи", "mumbai")
        add("Asia/Bangkok", "бангкок", "бангкоке", "bangkok", "пхукет", "пхукете", "phuket")
        add("Asia/Makassar", "бали", "bali")
        add("Asia/Singapore", "sgt", "сингапур", "сингапуре", "singapore")
        add("Asia/Hong_Kong", "hkt", "гонконг", "гонконге", "hong kong")
        add("Asia/Shanghai", "пекин", "пекине", "beijing", "шанхай", "шанхае", "shanghai")
        add("Asia/Seoul", "kst", "сеул", "сеуле", "seoul")
        add("Asia/Tokyo", "jst", "токио", "tokyo")
        add("Australia/Perth", "awst", "перт", "перте", "perth")
        add("Australia/Sydney", "aest", "aedt", "сидней", "сиднее", "sydney")
        add("Australia/Melbourne", "мельбурн", "мельбурне", "melbourne")
        add("Pacific/Auckland", "nzst", "nzdt", "окленд", "окленде", "auckland")
        add("America/New_York", "est", "edt", "нью-йорк", "нью-йорке", "new york", "nyc", "вашингтон", "вашингтоне",
            "washington", "майами", "miami")
        add("America/Toronto", "торонто", "toronto")
        add("America/Chicago", "cst", "cdt", "чикаго", "chicago")
        add("America/Denver", "mst", "mdt", "денвер", "денвере", "denver")
        add("America/Los_Angeles", "pst", "pdt", "лос-анджелес", "лос-анджелесе", "los angeles", "сан-франциско",
            "san francisco", "сиэтл", "сиэтле", "seattle")
        add("America/Vancouver", "ванкувер", "ванкувере", "vancouver")
        add("America/Anchorage", "akst", "akdt", "анкоридж", "анкоридже", "anchorage")
        add("Pacific/Honolulu", "hst", "гонолулу", "honolulu")
        add("America/Mexico_City", "мехико", "mexico city")
        add("America/Sao_Paulo", "сан-паулу", "sao paulo")
        add("America/Argentina/Buenos_Aires", "буэнос-айрес", "буэнос-айресе", "buenos aires")

        return zones
    }()

    static func valueAt(_ text: [Character], equalsIndex: Int, options: TimeZoneOptions) -> String? {
        var from = max(0, equalsIndex - maxScan)
        var index = equalsIndex - 1
        while index >= from {
            if text[index] == "\n" || text[index] == "=" {
                from = index + 1
                break
            }
            index -= 1
        }
        let words = String(text[from ..< equalsIndex])
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "−", with: "-")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
            .map(String.init)
        var end = words.count

        var target: TimeZone?
        for count in stride(from: maxZoneWords, through: 1, by: -1) {
            if end - count - 1 < 0 || !targetMarkers.contains(words[end - count - 1]) {
                continue
            }
            guard let zone = zone(words, from: end - count, to: end, places: options.places) else {
                continue
            }
            target = zone
            end -= count + 1
            break
        }

        var source: TimeZone?
        for count in stride(from: maxZoneWords, through: 1, by: -1) {
            if end - count < 1 {
                continue
            }
            guard let zone = zone(words, from: end - count, to: end, places: options.places) else {
                continue
            }
            source = zone
            end -= count
            if sourceMarkers.contains(words[end - 1]) && end > 1 {
                end -= 1
            }
            break
        }

        if end < 1 {
            return nil
        }
        var time = words[end - 1]
        if meridiems.contains(time) && end >= 2 {
            time = words[end - 2] + time
        }
        if source == nil && target == nil && !meridiems.contains(where: { time.hasSuffix($0) }) {
            return nil
        }

        let local = options.local
        let now = options.now ?? Date()
        if nowWords.contains(time) {
            guard let target, source == nil else {
                return nil
            }
            return format(minuteOfDay(now, in: target), meridiem: nil)
        }

        guard let parsed = parseTime(time) else {
            return nil
        }
        var hour = parsed.hour
        let meridiem = parsed.meridiem
        if parsed.minute == nil && meridiem == nil && source == nil {
            return nil
        }
        let minute = parsed.minute ?? 0
        if minute > 59 {
            return nil
        }
        if let meridiem {
            if hour < 1 || hour > 12 {
                return nil
            }
            hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
        } else if hour > 23 {
            return nil
        }

        if source == nil && target == nil {
            return format(hour * 60 + minute, meridiem: nil)
        }

        let sourceZone = source ?? local
        let targetZone = target ?? local
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceZone
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let start = calendar.date(from: components) else {
            return nil
        }
        // The same wall clock time in both zones is not a conversion.
        if sourceZone.secondsFromGMT(for: start) == targetZone.secondsFromGMT(for: start) {
            return nil
        }
        let shift = localDay(start, in: targetZone) - localDay(start, in: sourceZone)
        let value = format(minuteOfDay(start, in: targetZone), meridiem: meridiem)
        if shift > 0 {
            return "\(value) (+\(shift))"
        } else if shift < 0 {
            return "\(value) (\(shift))"
        } else {
            return value
        }
    }

    private static func localSeconds(_ date: Date, in zone: TimeZone) -> Int {
        return Int(date.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: date)
    }

    private static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        return value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
    }

    private static func localDay(_ date: Date, in zone: TimeZone) -> Int {
        return floorDivide(localSeconds(date, in: zone), 86400)
    }

    private static func minuteOfDay(_ date: Date, in zone: TimeZone) -> Int {
        let seconds = localSeconds(date, in: zone)
        return (seconds - floorDivide(seconds, 86400) * 86400) / 60
    }

    private static func pad(_ value: Int) -> String {
        return value < 10 ? "0\(value)" : "\(value)"
    }

    private static func format(_ minuteOfDay: Int, meridiem: String?) -> String {
        let hour = minuteOfDay / 60
        let minute = pad(minuteOfDay % 60)
        if meridiem == nil {
            return "\(pad(hour)):\(minute)"
        }
        return "\((hour + 11) % 12 + 1):\(minute) \(hour < 12 ? "am" : "pm")"
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.value >= 48 && scalar.value <= 57
    }

    private static func number(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
        return scalars.reduce(0) { $0 * 10 + Int($1.value) - 48 }
    }

    // One or two digits, optional ":mm" or ".mm", optional am/pm.
    private static func parseTime(_ text: String) -> (hour: Int, minute: Int?, meridiem: String?)? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count && index < 2 && isDigit(scalars[index]) {
            index += 1
        }
        if index == 0 {
            return nil
        }
        let hour = number(scalars[0 ..< index])
        var minute: Int?
        if index + 2 < scalars.count, scalars[index] == ":" || scalars[index] == ".", isDigit(scalars[index + 1]), isDigit(scalars[index + 2]) {
            minute = number(scalars[index + 1 ... index + 2])
            index += 3
        }
        if index == scalars.count {
            return (hour, minute, nil)
        }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[index...])
        let meridiem = String(rest)
        guard meridiems.contains(meridiem) else {
            return nil
        }
        return (hour, minute, meridiem)
    }

    // "utc+5", "gmt -5:30", "msk+0530": minutes east of Greenwich.
    private static func parseOffset(_ key: String) -> Int? {
        guard let prefix = offsetPrefixes.first(where: { key.hasPrefix($0) }) else {
            return nil
        }
        var scalars = ArraySlice(Array(key.unicodeScalars).dropFirst(prefix.unicodeScalars.count))
        if scalars.first == " " {
            scalars.removeFirst()
        }
        guard let signScalar = scalars.first, signScalar == "+" || signScalar == "-" else {
            return nil
        }
        scalars.removeFirst()
        if scalars.first == " " {
            scalars.removeFirst()
        }
        let hours: Int
        var minutes = 0
        if let colon = scalars.firstIndex(of: ":") {
            let left = scalars[scalars.startIndex ..< colon]
            let right = scalars[(colon + 1)...]
            guard (1 ... 2).contains(left.count), right.count == 2, left.allSatisfy(isDigit), right.allSatisfy(isDigit) else {
                return nil
            }
            hours = number(left)
            minutes = number(right)
        } else {
            guard (1 ... 4).contains(scalars.count), scalars.allSatisfy(isDigit) else {
                return nil
            }
            if scalars.count <= 2 {
                hours = number(scalars)
            } else {
                let split = scalars.endIndex - 2
                hours = number(scalars[scalars.startIndex ..< split])
                minutes = number(scalars[split...])
            }
        }
        if hours > maxOffsetHours || minutes > 59 {
            return nil
        }
        let base = prefix == "msk" || prefix == "мск" ? moscowOffsetHours * 60 : 0
        let total = base + (signScalar == "-" ? -1 : 1) * (hours * 60 + minutes)
        return abs(total) <= maxOffsetHours * 60 ? total : nil
    }

    private static func zone(_ words: [String], from: Int, to: Int, places: ((String) -> String?)?) -> TimeZone? {
        let key = words[from ..< to].joined(separator: " ")
        for name in forms(normalize(key)) {
            guard let id = zones[name] ?? places?(name) else {
                continue
            }
            return TimeZone(identifier: id)
        }
        guard let minutes = parseOffset(key) else {
            return nil
        }
        return TimeZone(secondsFromGMT: minutes * 60)
    }

    // Russian case endings back to the dictionary form: "в берлине" -> "берлин".
    private static func forms(_ name: String) -> [String] {
        let scalars = Array(name.unicodeScalars)
        for (ending, replacements) in caseEndings {
            let length = ending.unicodeScalars.count
            if scalars.count > length + 2 && scalars.suffix(length).elementsEqual(ending.unicodeScalars) {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars.dropLast(length))
                let stem = String(view)
                return [name] + replacements.map { stem + $0 }
            }
        }
        return [name]
    }

    static func normalize(_ name: String) -> String {
        return name.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "-", with: " ")
    }
}
