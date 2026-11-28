// Ported from exteraGram for Android (com.exteragram.messenger.inline.docs.InlineExamples), GPL v3 or later, © exteraGram.

import Foundation

public struct InlineExampleGroup {
    private let english: [String]
    private let russian: [String]

    init(_ english: [String], _ russian: [String]? = nil) {
        self.english = english
        self.russian = russian ?? english
    }

    public func examples(russian: Bool) -> [String] {
        return russian ? self.russian : self.english
    }
}

// What can be typed in the message field, for the settings screen.
public enum InlineExamples {
    public static let functions = ["round", "min", "max", "abs", "sqrt", "log", "ln", "sin", "cos", "tan", "pi", "e"]

    public static let arithmetic = InlineExampleGroup(["(120 + 80) / 4 =", "√144 + 2^3 ="])
    public static let arithmeticFunctions = InlineExampleGroup(["max(12, 40, 7) =", "sin(30) ="])
    public static let bases = InlineExampleGroup(["hex(255) =", "dec(ff, 16) =", "0xff + 1 ="])

    public static let percentages = InlineExampleGroup(["2300 - 15% =", "12% of 1200 ="], ["2300 - 15% =", "12% от 1200 ="])
    public static let shorthands = InlineExampleGroup(["300k / 12 ="], ["300к / 12 ="])

    public static let currencyDefault = InlineExampleGroup(["100€ =", "500 stars ="], ["100€ =", "500 звёзд ="])
    public static let currencyTarget = InlineExampleGroup(
        ["100 dollars to euros =", "5k ₽ to $ =", "50$ to GRAM ="],
        ["100 долларов в евро =", "5к ₽ в $ =", "50$ в GRAM ="]
    )

    public static let unitsDefault = InlineExampleGroup(["72°F =", "10 miles ="], ["72°F =", "10 миль ="])
    public static let unitsTarget = InlineExampleGroup(["5 kg to lb =", "100 km/h to mph ="], ["5 кг в фунтах =", "100 км/ч в mph ="])
    public static let durations = InlineExampleGroup(["90 min =", "2 h + 45 min ="], ["90 мин =", "2 ч + 45 мин ="])

    public static let timeZones = InlineExampleGroup(["6pm est =", "12:00 in tokyo ="], ["18:00 utc =", "12:00 в токио ="])
    public static let currentTime = InlineExampleGroup(["now in new york ="], ["сейчас в нью-йорке ="])

    public static let all = [
        arithmetic, arithmeticFunctions, bases, percentages, shorthands, currencyDefault, currencyTarget,
        unitsDefault, unitsTarget, durations, timeZones, currentTime
    ]

    // Russian examples are also shown for Belarusian, as on Android.
    public static func isRussian(language: String) -> Bool {
        return language == "ru" || language == "be"
    }
}
