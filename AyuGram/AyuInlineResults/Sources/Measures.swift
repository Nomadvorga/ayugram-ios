// Ported from exteraGram for Android (com.exteragram.messenger.inline.units), GPL v3 or later, © exteraGram.

import Foundation

enum Measures {
    private static let celsiusOffset = 273.15
    private static let fahrenheitScale = 5.0 / 9.0
    private static let minRescaled = 0.1
    private static let maxRescaled = 1000.0
    private static let maxSteppedDown = 100_000.0

    private final class Ladder {
        let imperial: Bool
        let codes: [String]

        init(imperial: Bool, codes: [String]) {
            self.imperial = imperial
            self.codes = codes
        }
    }

    private struct Tables {
        var units: [String: MathUnit] = [:]
        var words: [String: String] = [:]
        var counterparts: [String: String] = [:]
        var compounds: [String: String] = [:]
        var ladders: [String: Ladder] = [:]
    }

    private static let breakdown = ["d", "h", "min", "s"]

    private static let tables: Tables = {
        var tables = Tables()

        func unit(_ code: String, _ label: String, _ russianLabel: String, _ kind: UnitKind, _ scale: Double, _ counterpart: String?, _ forms: [String], offset: Double = 0.0) {
            tables.units[code] = MathUnit(code: code, label: label, kind: kind, scale: scale, offset: offset, russianLabel: russianLabel)
            if let counterpart {
                tables.counterparts[code] = counterpart
            }
            for form in forms {
                tables.words[form] = code
            }
        }

        unit("mm", "mm", "мм", .length, 0.001, "in", [
            "mm", "мм", "миллиметр", "миллиметра", "миллиметров", "миллиметрах",
            "millimeter", "millimeters", "millimetre", "millimetres"
        ])
        unit("cm", "cm", "см", .length, 0.01, "in", [
            "cm", "см", "сантиметр", "сантиметра", "сантиметров", "сантиметрах",
            "centimeter", "centimeters", "centimetre", "centimetres"
        ])
        unit("m", "m", "м", .length, 1.0, "ft", [
            "m", "м", "метр", "метра", "метров", "метрах", "meter", "meters", "metre", "metres"
        ])
        unit("km", "km", "км", .length, 1000.0, "mi", [
            "km", "км", "километр", "километра", "километров", "километрах",
            "kilometer", "kilometers", "kilometre", "kilometres"
        ])
        unit("in", "in", "in", .length, 0.0254, "cm", ["inch", "inches", "дюйм", "дюйма", "дюймов", "дюймах"])
        unit("ft", "ft", "ft", .length, 0.3048, "m", ["ft", "foot", "feet", "фут", "фута", "футов", "футах"])
        unit("yd", "yd", "yd", .length, 0.9144, "m", ["yd", "yard", "yards", "ярд", "ярда", "ярдов", "ярдах"])
        unit("mi", "mi", "mi", .length, 1609.344, "km", ["mi", "mile", "miles", "миля", "мили", "миль", "милях"])

        unit("mg", "mg", "мг", .mass, 0.000001, nil, [
            "mg", "мг", "миллиграмм", "миллиграмма", "миллиграммов", "milligram", "milligrams"
        ])
        unit("g", "g", "г", .mass, 0.001, "oz", [
            "g", "г", "гр", "грамм", "грамма", "граммов", "граммах", "gram", "grams", "gramme", "grammes"
        ])
        unit("kg", "kg", "кг", .mass, 1.0, "lb", [
            "kg", "кг", "килограмм", "килограмма", "килограммов", "килограммах", "kilogram", "kilograms", "kilo", "kilos"
        ])
        unit("t", "t", "т", .mass, 1000.0, "lb", ["t", "т", "тонна", "тонны", "тонн", "тоннах", "tonne", "tonnes"])
        unit("oz", "oz", "oz", .mass, 0.028349523125, "g", ["oz", "ounce", "ounces", "унция", "унции", "унций", "унциях"])
        unit("lb", "lb", "lb", .mass, 0.45359237, "kg", ["lb", "lbs", "pound", "pounds", "фунт", "фунта", "фунтов", "фунтах"])

        unit("ml", "ml", "мл", .volume, 0.001, "floz", [
            "ml", "мл", "миллилитр", "миллилитра", "миллилитров", "миллилитрах",
            "milliliter", "milliliters", "millilitre", "millilitres"
        ])
        unit("l", "l", "л", .volume, 1.0, "gal", [
            "l", "л", "литр", "литра", "литров", "литрах", "liter", "liters", "litre", "litres"
        ])
        unit("floz", "fl oz", "fl oz", .volume, 0.0295735295625, "ml", ["floz"])
        unit("gal", "gal", "gal", .volume, 3.785411784, "l", ["gal", "gallon", "gallons", "галлон", "галлона", "галлонов", "галлонах"])

        unit("m2", "m²", "м²", .area, 1.0, "ft2", ["m2", "m²", "м2", "м²", "sqm"])
        unit("km2", "km²", "км²", .area, 1_000_000.0, "mi2", ["km2", "km²", "км2", "км²"])
        unit("ha", "ha", "га", .area, 10_000.0, "acre", [
            "ha", "га", "гектар", "гектара", "гектаров", "гектарах", "hectare", "hectares"
        ])
        unit("ft2", "ft²", "ft²", .area, 0.09290304, "m2", ["ft2", "ft²", "sqft"])
        unit("mi2", "mi²", "mi²", .area, 2_589_988.110336, "km2", ["mi2", "mi²"])
        unit("acre", "ac", "ac", .area, 4046.8564224, "ha", ["ac", "acre", "acres", "акр", "акра", "акров", "акрах"])

        unit("kmh", "km/h", "км/ч", .speed, 1.0 / 3.6, "mph", ["kmh", "kph"])
        unit("ms", "m/s", "м/с", .speed, 1.0, "kmh", ["mps"])
        unit("mph", "mph", "mph", .speed, 0.44704, "kmh", ["mph"])
        unit("knot", "kn", "уз", .speed, 1852.0 / 3600.0, "kmh", ["knot", "knots", "узел", "узла", "узлов", "узлах"])

        unit("C", "°C", "°C", .temperature, 1.0, "F", [
            "celsius", "цельсий", "цельсия", "цельсию", "цельсиях"
        ], offset: celsiusOffset)
        unit("F", "°F", "°F", .temperature, fahrenheitScale, "C", [
            "fahrenheit", "фаренгейт", "фаренгейта", "фаренгейту", "фаренгейтах"
        ], offset: celsiusOffset - 32.0 * fahrenheitScale)
        unit("K", "K", "K", .temperature, 1.0, "C", ["kelvin", "kelvins", "кельвин", "кельвина", "кельвинов", "кельвинах"])

        unit("msec", "ms", "мс", .duration, 0.001, nil, [
            "ms", "мс", "millisecond", "milliseconds", "миллисекунда", "миллисекунды", "миллисекунд"
        ])
        unit("s", "s", "с", .duration, 1.0, nil, [
            "s", "sec", "secs", "second", "seconds", "с", "сек", "секунда", "секунды", "секунд", "секундах", "секунду"
        ])
        unit("min", "min", "мин", .duration, 60.0, nil, [
            "min", "mins", "minute", "minutes", "мин", "минута", "минуты", "минут", "минутах", "минуту"
        ])
        unit("h", "h", "ч", .duration, 3600.0, nil, [
            "h", "hr", "hrs", "hour", "hours", "ч", "час", "часа", "часов", "часах"
        ])
        unit("d", "d", "д", .duration, 86_400.0, nil, [
            "d", "day", "days", "д", "дн", "день", "дня", "дней", "днях", "сут", "сутки", "суток"
        ])
        unit("w", "w", "нед", .duration, 604_800.0, nil, [
            "w", "wk", "week", "weeks", "нед", "неделя", "недели", "недель", "неделях", "неделю"
        ])
        unit("mo", "mo", "мес", .duration, 2_592_000.0, nil, [
            "mo", "month", "months", "мес", "месяц", "месяца", "месяцев", "месяцах"
        ])
        unit("y", "y", "г.", .duration, 31_536_000.0, nil, [
            "y", "yr", "yrs", "year", "years", "год", "года", "лет", "годах"
        ])

        tables.compounds["km/h"] = "kmh"
        tables.compounds["км/ч"] = "kmh"
        tables.compounds["m/s"] = "ms"
        tables.compounds["м/с"] = "ms"
        tables.compounds["fl oz"] = "floz"

        @discardableResult
        func ladder(_ imperial: Bool, _ codes: String...) -> Ladder {
            let ladder = Ladder(imperial: imperial, codes: codes)
            for code in codes {
                tables.ladders[code] = ladder
            }
            return ladder
        }

        ladder(false, "mm", "cm", "m", "km")
        ladder(false, "mg", "g", "kg", "t")
        ladder(false, "ml", "l")
        ladder(false, "m2", "ha", "km2")
        // Yards are not a rung themselves, but rescale along the inch / foot / mile ladder.
        tables.ladders["yd"] = ladder(true, "in", "ft", "mi")
        ladder(true, "oz", "lb")
        ladder(true, "floz", "gal")
        ladder(true, "ft2", "acre", "mi2")

        return tables
    }()

    static func word(_ word: String) -> MathUnit? {
        guard let code = tables.words[word.lowercased()] else {
            return nil
        }
        return tables.units[code]
    }

    static func compound(_ first: String, separator: Character, _ second: String) -> MathUnit? {
        let key = first.lowercased() + String(separator) + second.lowercased()
        guard let code = tables.compounds[key] else {
            return nil
        }
        return tables.units[code]
    }

    static func temperature(_ scale: Character) -> MathUnit? {
        switch scale {
        case "C", "c", "С", "с":
            return tables.units["C"]
        case "F", "f", "Ф", "ф":
            return tables.units["F"]
        case "K", "k", "К", "к":
            return tables.units["K"]
        default:
            return nil
        }
    }

    static func symbol(_ character: Character) -> MathUnit? {
        switch character {
        case "℃":
            return tables.units["C"]
        case "℉":
            return tables.units["F"]
        default:
            return nil
        }
    }

    static func implicitTarget(_ unit: MathUnit, value: Double, imperial: Bool) -> MathUnit? {
        if let ladder = tables.ladders[unit.code], ladder.imperial == imperial {
            if let target = rescale(ladder, unit, base: abs(unit.toBase(value))) {
                return target
            }
        }
        guard let counterpart = tables.counterparts[unit.code] else {
            return nil
        }
        return tables.units[counterpart]
    }

    private static func rescale(_ ladder: Ladder, _ unit: MathUnit, base: Double) -> MathUnit? {
        for code in ladder.codes.reversed() {
            guard let target = tables.units[code] else {
                continue
            }
            let amount = target.fromBase(base)
            if code != unit.code && amount >= minRescaled && amount < maxRescaled {
                return target
            }
        }
        guard let index = ladder.codes.firstIndex(of: unit.code), index > 0, let smaller = tables.units[ladder.codes[index - 1]] else {
            return nil
        }
        let amount = smaller.fromBase(base)
        return amount >= 1.0 && amount < maxSteppedDown ? smaller : nil
    }

    static func canBreakDown(_ unit: MathUnit) -> Bool {
        return breakdown.contains(unit.code)
    }

    static func breaksDown(_ value: Double, unit: MathUnit) -> Bool {
        if !breakdown.contains(unit.code) {
            return false
        }
        guard let parts = parts(abs(value * unit.scale)) else {
            return false
        }
        return parts.count > 1 || parts[0].0 != unit.code
    }

    static func formatDuration(_ seconds: Double, decimalSeparator: Character, russian: Bool) -> String? {
        if seconds.isNaN || seconds.isInfinite {
            return nil
        }
        guard let parts = parts(abs(seconds)) else {
            return nil
        }
        var text = ""
        if seconds < 0.0 {
            text.append("-")
        }
        for (index, part) in parts.enumerated() {
            if index > 0 {
                text.append(" ")
            }
            guard let number = MathFormat.format(part.1, decimalSeparator: decimalSeparator, grouping: false), let unit = tables.units[part.0] else {
                return nil
            }
            text.append(number)
            text.append(MathFormat.noBreakSpace)
            text.append(unit.label(russian: russian))
        }
        return text
    }

    private static func parts(_ seconds: Double) -> [(String, Double)]? {
        if !seconds.isFinite || seconds >= 1e12 {
            return nil
        }
        if seconds < 60.0 {
            return [("s", seconds)]
        }
        var rest = Int64((seconds + 0.5).rounded(.down))
        var parts: [(String, Double)] = []
        for code in breakdown {
            guard let unit = tables.units[code] else {
                continue
            }
            let size = Int64(unit.scale)
            let amount = rest / size
            if amount > 0 {
                parts.append((code, Double(amount)))
                rest -= amount * size
            }
        }
        return parts.isEmpty ? [("s", 0.0)] : parts
    }
}
