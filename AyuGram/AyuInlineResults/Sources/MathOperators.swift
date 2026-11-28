// Ported from exteraGram for Android (com.exteragram.messenger.inline.math), GPL v3 or later, © exteraGram.

import Foundation

enum UnitRule {
    case same
    case scale
    case ratio
    case none
}

struct InfixOperator {
    let symbols: [String]
    let precedence: Int
    let units: UnitRule
    var rightAssociative: Bool = false
    let apply: (_ left: Double, _ right: Double, _ rightIsPercent: Bool) -> Double
}

struct PrefixOperator {
    let symbols: [String]
    let precedence: Int
    var operation: Bool = false
    let apply: (Double) -> Double
}

struct PostfixOperator {
    let symbols: [String]
    var percent: Bool = false
    let apply: (Double) -> Double
}

enum AngleUse {
    case none
    case argument
    case result
}

struct MathFunction {
    let name: String
    let arity: ClosedRange<Int>
    var angle: AngleUse = .none
    let apply: ([Double]) -> Double
}

enum MathOperators {
    static let precedenceAdditive = 10
    static let precedenceMultiplicative = 20
    static let precedencePrefix = 30
    static let precedencePower = 40

    static let argumentSeparator: Character = ";"

    private static let maxFactorial = 170.0

    static let infix: [InfixOperator] = [
        InfixOperator(symbols: ["+"], precedence: precedenceAdditive, units: .same, apply: { left, right, percent in
            return percent ? left + left * right : left + right
        }),
        InfixOperator(symbols: ["-", "−"], precedence: precedenceAdditive, units: .same, apply: { left, right, percent in
            return percent ? left - left * right : left - right
        }),
        InfixOperator(symbols: ["*", "×"], precedence: precedenceMultiplicative, units: .scale, apply: { left, right, _ in
            return left * right
        }),
        InfixOperator(symbols: ["/", "÷"], precedence: precedenceMultiplicative, units: .ratio, apply: { left, right, _ in
            return left / right
        }),
        InfixOperator(symbols: ["^"], precedence: precedencePower, units: .none, rightAssociative: true, apply: { left, right, _ in
            return pow(left, right)
        })
    ]

    static let prefix: [PrefixOperator] = [
        PrefixOperator(symbols: ["-", "−"], precedence: precedencePrefix, apply: { -$0 }),
        PrefixOperator(symbols: ["+"], precedence: precedencePrefix, apply: { $0 }),
        PrefixOperator(symbols: ["√"], precedence: precedencePower, operation: true, apply: { sqrt($0) })
    ]

    static let postfix: [PostfixOperator] = [
        PostfixOperator(symbols: ["%"], percent: true, apply: { $0 / 100.0 }),
        PostfixOperator(symbols: ["!"], apply: { factorial($0) })
    ]

    static let functions: [MathFunction] = [
        MathFunction(name: "sqrt", arity: 1 ... 1, apply: { sqrt($0[0]) }),
        MathFunction(name: "cbrt", arity: 1 ... 1, apply: { cbrt($0[0]) }),
        MathFunction(name: "abs", arity: 1 ... 1, apply: { abs($0[0]) }),
        MathFunction(name: "sign", arity: 1 ... 1, apply: { sign($0[0]) }),
        MathFunction(name: "round", arity: 1 ... 1, apply: { roundHalfUp($0[0]) }),
        MathFunction(name: "floor", arity: 1 ... 1, apply: { floor($0[0]) }),
        MathFunction(name: "ceil", arity: 1 ... 1, apply: { ceil($0[0]) }),
        MathFunction(name: "fact", arity: 1 ... 1, apply: { factorial($0[0]) }),
        MathFunction(name: "min", arity: 1 ... Int.max, apply: { args in
            return args.contains(where: { $0.isNaN }) ? Double.nan : (args.min() ?? Double.nan)
        }),
        MathFunction(name: "max", arity: 1 ... Int.max, apply: { args in
            return args.contains(where: { $0.isNaN }) ? Double.nan : (args.max() ?? Double.nan)
        }),
        MathFunction(name: "log", arity: 1 ... 1, apply: { log10($0[0]) }),
        MathFunction(name: "log2", arity: 1 ... 1, apply: { log2($0[0]) }),
        MathFunction(name: "ln", arity: 1 ... 1, apply: { log($0[0]) }),
        MathFunction(name: "exp", arity: 1 ... 1, apply: { exp($0[0]) }),
        MathFunction(name: "sin", arity: 1 ... 1, angle: .argument, apply: { sin($0[0]) }),
        MathFunction(name: "cos", arity: 1 ... 1, angle: .argument, apply: { cos($0[0]) }),
        MathFunction(name: "tan", arity: 1 ... 1, angle: .argument, apply: { tan($0[0]) }),
        MathFunction(name: "asin", arity: 1 ... 1, angle: .result, apply: { asin($0[0]) }),
        MathFunction(name: "acos", arity: 1 ... 1, angle: .result, apply: { acos($0[0]) }),
        MathFunction(name: "atan", arity: 1 ... 1, angle: .result, apply: { atan($0[0]) }),
        MathFunction(name: "atan2", arity: 2 ... 2, angle: .result, apply: { atan2($0[0], $0[1]) }),
        MathFunction(name: "sinh", arity: 1 ... 1, apply: { sinh($0[0]) }),
        MathFunction(name: "cosh", arity: 1 ... 1, apply: { cosh($0[0]) }),
        MathFunction(name: "tanh", arity: 1 ... 1, apply: { tanh($0[0]) })
    ]

    static let multipliers: [String: Double] = {
        var result: [String: Double] = [:]
        for form in ["к", "k", "тыс", "тысяча", "тысячи", "тысяч", "thousand", "thousands"] {
            result[form] = 1e3
        }
        for form in ["кк", "kk", "млн", "миллион", "миллиона", "миллионов", "million", "millions"] {
            result[form] = 1e6
        }
        for form in ["ккк", "kkk", "млрд", "миллиард", "миллиарда", "миллиардов", "billion", "billions"] {
            result[form] = 1e9
        }
        return result
    }()

    static let gluedMultipliers: Set<String> = ["к", "k", "кк", "kk", "ккк", "kkk"]

    static let percentOf: Set<String> = ["от", "of"]

    static let decimal = "dec"
    static let minRadix = 2
    static let maxRadix = 36

    static let bases: [String: Int] = ["bin": 2, "oct": 8, "hex": 16, decimal: 10]

    static func radixFor(_ prefix: Character) -> Int {
        switch prefix {
        case "b", "B":
            return 2
        case "o", "O":
            return 8
        case "x", "X":
            return 16
        default:
            return 0
        }
    }

    static func stripRadixPrefix(_ digits: String, radix: Int) -> String {
        let characters = Array(digits)
        if characters.count > 2 && characters[0] == "0" && radixFor(characters[1]) == radix {
            return String(characters[2...])
        }
        return digits
    }

    static let constants: [String: Double] = [
        "pi": Double.pi,
        "π": Double.pi,
        "e": M_E
    ]

    // Longest first, so that a longer symbol wins over its own prefix.
    private static let symbols: [[Character]] = {
        var seen = Set<String>()
        var result: [String] = []
        for symbol in infix.flatMap({ $0.symbols }) + prefix.flatMap({ $0.symbols }) + postfix.flatMap({ $0.symbols }) {
            if seen.insert(symbol).inserted {
                result.append(symbol)
            }
        }
        return result.enumerated().sorted(by: { lhs, rhs in
            if lhs.element.count != rhs.element.count {
                return lhs.element.count > rhs.element.count
            }
            return lhs.offset < rhs.offset
        }).map { mathCharacters($0.element) }
    }()

    static let symbolChars: Set<Character> = {
        var result = Set<Character>()
        for symbol in symbols {
            result.formUnion(symbol)
        }
        for name in constants.keys {
            for character in mathCharacters(name) where !character.isMathLetter {
                result.insert(character)
            }
        }
        result.insert("(")
        result.insert(")")
        result.insert(argumentSeparator)
        return result
    }()

    static func matchSymbol(_ text: [Character], at index: Int) -> String? {
        for symbol in symbols {
            if index + symbol.count <= text.count && Array(text[index ..< index + symbol.count]) == symbol {
                return String(symbol)
            }
        }
        return nil
    }

    static func infixFor(_ symbol: String) -> InfixOperator? {
        return infix.first(where: { $0.symbols.contains(symbol) })
    }

    static func prefixFor(_ symbol: String) -> PrefixOperator? {
        return prefix.first(where: { $0.symbols.contains(symbol) })
    }

    static func postfixFor(_ symbol: String) -> PostfixOperator? {
        return postfix.first(where: { $0.symbols.contains(symbol) })
    }

    static func functionFor(_ name: String) -> MathFunction? {
        return functions.first(where: { $0.name == name })
    }

    private static func sign(_ value: Double) -> Double {
        if value.isNaN || value == 0.0 {
            return value
        }
        return value > 0.0 ? 1.0 : -1.0
    }

    // Ties go towards positive infinity, like Math.round.
    private static func roundHalfUp(_ value: Double) -> Double {
        if !value.isFinite {
            return Double.nan
        }
        let lower = value.rounded(.down)
        return value - lower >= 0.5 ? lower + 1.0 : lower
    }

    private static func factorial(_ value: Double) -> Double {
        if value.isNaN || value < 0.0 || value != floor(value) || value > maxFactorial {
            return Double.nan
        }
        var result = 1.0
        if value >= 2.0 {
            for i in 2 ... Int(value) {
                result *= Double(i)
            }
        }
        return result
    }
}
