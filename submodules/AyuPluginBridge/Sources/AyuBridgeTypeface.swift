import Foundation
import UIKit

/// Android `Typeface` as a value: the system family, the family's own weight (the base of
/// `Typeface.create(family, style)`), the effective weight and the API style `getStyle()` reports.
struct AyuBridgeTypefaceValue: Equatable, Sendable {
    static let className = "android.graphics.Typeface"

    /// `rounded` is no Android family: it stands for the Nunito asset of `AndroidUtilities.getTypeface`.
    enum Design: String, Sendable, CaseIterable {
        case sans = "sans-serif"
        case condensed = "sans-serif-condensed"
        case serif
        case monospace
        case rounded
    }

    var design: Design
    var baseWeight: Int64
    var weight: Int64
    var style: Int64

    var isItalic: Bool { self.style & 2 != 0 }
    var isBold: Bool { self.style & 1 != 0 }

    static let `default` = AyuBridgeTypefaceValue(design: .sans, baseWeight: 400, weight: 400, style: 0)

    /// Families of Android's `fonts.xml` that iOS system fonts cover, with their weight.
    private static let families: [String: (Design, Int64)] = [
        "sans-serif": (.sans, 400), "sans-serif-thin": (.sans, 100), "sans-serif-light": (.sans, 300),
        "sans-serif-medium": (.sans, 500), "sans-serif-black": (.sans, 900),
        "sans-serif-condensed": (.condensed, 400), "sans-serif-condensed-light": (.condensed, 300),
        "sans-serif-condensed-medium": (.condensed, 500),
        "serif": (.serif, 400), "monospace": (.monospace, 400),
    ]
    /// Android families with no iOS system counterpart: refused rather than drawn as another face.
    private static let unavailableFamilies: Set<String> = ["serif-monospace", "casual", "cursive", "sans-serif-smallcaps"]

    /// `Typeface.create(String familyName, int style)`. Android resolves an unknown name to the default family.
    static func family(_ name: String?) throws -> AyuBridgeTypefaceValue {
        guard let name, !name.isEmpty else { return .default }
        guard name.utf8.count <= 256 else { throw AyuBridgeFailure("invalid_arguments", "Typeface family name is too long") }
        if Self.unavailableFamilies.contains(name) { throw AyuBridgeFailure.unsupported("Typeface family " + name) }
        guard let (design, weight) = Self.families[name] else { return .default }
        return AyuBridgeTypefaceValue(design: design, baseWeight: weight, weight: weight, style: 0)
    }

    /// `Typeface.create(Typeface family, int style)`: bold adds 300 to the family's base weight.
    func styled(_ requested: Int64) -> AyuBridgeTypefaceValue {
        let style = (0...3).contains(requested) ? requested : 0
        if self.style == style { return self }
        var result = self
        result.weight = min(1000, self.baseWeight + (style & 1 != 0 ? 300 : 0))
        result.style = style
        return result
    }

    /// `Typeface.create(Typeface family, int weight, boolean italic)`.
    func weighted(_ weight: Int64, italic: Bool) throws -> AyuBridgeTypefaceValue {
        guard (1...1000).contains(weight) else { throw AyuBridgeFailure("invalid_arguments", "Typeface weight must be in 1...1000") }
        var result = self
        result.weight = weight
        result.style = (weight >= 600 ? 1 : 0) | (italic ? 2 : 0)
        return result
    }

    /// The system typeface exteraGram uses for a bundled font asset (`FontUtils.getSystemTypeface`).
    /// The two assets without a system typeface there (Merriweather Bold, Nunito ExtraBold) map to
    /// the iOS serif and rounded system designs at their weight; any other path is null, as on Android.
    static func asset(_ path: String) -> AyuBridgeTypefaceValue? {
        switch path {
        case "fonts/rmono.ttf": return AyuBridgeTypefaceValue(design: .monospace, baseWeight: 400, weight: 400, style: 0)
        case "fonts/rcondensedbold.ttf": return AyuBridgeTypefaceValue(design: .condensed, baseWeight: 400, weight: 700, style: 1)
        case "fonts/rmediumitalic.ttf": return AyuBridgeTypefaceValue(design: .sans, baseWeight: 400, weight: 500, style: 2)
        case "fonts/rmedium.ttf": return AyuBridgeTypefaceValue(design: .sans, baseWeight: 400, weight: 500, style: 0)
        case "fonts/ritalic.ttf": return AyuBridgeTypefaceValue(design: .sans, baseWeight: 400, weight: 400, style: 2)
        case "fonts/rregular.ttf": return AyuBridgeTypefaceValue(design: .sans, baseWeight: 400, weight: 400, style: 0)
        case "fonts/rextrabold.ttf": return AyuBridgeTypefaceValue(design: .sans, baseWeight: 400, weight: 800, style: 1)
        case "fonts/mw_bold.ttf": return AyuBridgeTypefaceValue(design: .serif, baseWeight: 700, weight: 700, style: 0)
        case "fonts/nunito_extrabold.ttf": return AyuBridgeTypefaceValue(design: .rounded, baseWeight: 800, weight: 800, style: 0)
        default: return nil
        }
    }

    // MARK: Adapter state

    var state: [String: AyuBridgeValue] {
        ["family": .string(self.design.rawValue), "base": .integer(self.baseWeight), "weight": .integer(self.weight), "style": .integer(self.style)]
    }

    init(design: Design, baseWeight: Int64, weight: Int64, style: Int64) {
        self.design = design; self.baseWeight = baseWeight; self.weight = weight; self.style = style
    }

    init(state: [String: AyuBridgeValue]) throws {
        guard state.count == 4, let family = state["family"]?.string, let design = Design(rawValue: family),
              let base = state["base"]?.integer, (1...1000).contains(base),
              let weight = state["weight"]?.integer, (1...1000).contains(weight),
              let style = state["style"]?.integer, (0...3).contains(style) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Typeface state")
        }
        self.init(design: design, baseWeight: base, weight: weight, style: style)
    }

    /// A Typeface argument: null, or an owned `android.graphics.Typeface`.
    static func argument(_ value: AyuBridgeValue, context: AyuBridgeAdapterContext) throws -> AyuBridgeTypefaceValue? {
        if value == .null { return nil }
        let snapshot = try context.snapshot(of: value)
        guard snapshot.className == Self.className else { throw AyuBridgeFailure.unsupported("Typeface reference") }
        return try AyuBridgeTypefaceValue(state: snapshot.state)
    }

    // MARK: UI command form

    private static let packedMarker: Int64 = 0x1_0000

    /// The integer a `setTypefaceStyle` UI command carries; 0 is the default typeface.
    var packed: Int64 {
        let design = Int64(Design.allCases.firstIndex(of: self.design) ?? 0)
        return Self.packedMarker | design << 12 | (self.isItalic ? 1 : 0) << 11 | self.weight
    }

    init?(packed: Int64) {
        guard packed & ~0xFFFF == Self.packedMarker else { return nil }
        let design = Int(packed >> 12 & 0xF), weight = packed & 0x7FF
        guard Design.allCases.indices.contains(design), (1...1000).contains(weight) else { return nil }
        let italic = packed & 0x800 != 0
        self.init(design: Design.allCases[design], baseWeight: weight, weight: weight, style: (weight >= 600 ? 1 : 0) | (italic ? 2 : 0))
    }

    private var fontWeight: UIFont.Weight {
        // Android draws the nearest weight the family has; the system families step by 100.
        switch (self.weight + 50) / 100 {
        case ...1: return .ultraLight
        case 2: return .thin
        case 3: return .light
        case 4: return .regular
        case 5: return .medium
        case 6: return .semibold
        case 7: return .bold
        case 8: return .heavy
        default: return .black
        }
    }

    @MainActor func font(size: CGFloat) -> UIFont {
        var font: UIFont
        switch self.design {
        case .sans: font = .systemFont(ofSize: size, weight: self.fontWeight)
        case .monospace: font = .monospacedSystemFont(ofSize: size, weight: self.fontWeight)
        case .serif, .rounded:
            font = .systemFont(ofSize: size, weight: self.fontWeight)
            if let descriptor = font.fontDescriptor.withDesign(self.design == .serif ? .serif : .rounded) {
                font = UIFont(descriptor: descriptor, size: size)
            }
        case .condensed:
            if #available(iOS 16.0, *) {
                font = .systemFont(ofSize: size, weight: self.fontWeight, width: .condensed)
            } else {
                font = .systemFont(ofSize: size, weight: self.fontWeight)
                if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitCondensed)) {
                    font = UIFont(descriptor: descriptor, size: size)
                }
            }
        }
        guard self.isItalic else { return font }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            return UIFont(descriptor: descriptor, size: size)
        }
        // A family without an italic face is slanted, as Android's text skew of -0.25 does.
        let slant = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
        return UIFont(descriptor: font.fontDescriptor.withMatrix(slant), size: size)
    }

    // MARK: TextView.setTypeface

    struct TextViewTypeface {
        /// Nil is the default typeface (`getTypeface()` returns null).
        let value: AyuBridgeTypefaceValue?
        /// The owned Typeface `getTypeface()` returns as the same object, when it is the one passed in.
        let handle: String?
        var packed: Int64 { self.value?.packed ?? 0 }
    }

    /// `TextView.setTypeface(tf)` and `setTypeface(tf, style)`. With a style above zero Android sets
    /// `Typeface.create(tf, style)`, or the default typeface of that style for a null `tf`.
    static func textViewTypeface(_ args: [AyuBridgeValue], resolve: (AyuBridgeValue) throws -> (handle: String, state: [String: AyuBridgeValue])?) throws -> TextViewTypeface {
        guard args.count == 1 || args.count == 2 else { throw AyuBridgeFailure("invalid_arguments", "setTypeface takes a Typeface and an optional style") }
        let reference = try resolve(args[0])
        let typeface = try reference.map { try AyuBridgeTypefaceValue(state: $0.state) }
        guard args.count == 2 else { return TextViewTypeface(value: typeface, handle: reference?.handle) }
        guard let style = args[1].integer, (0...3).contains(style) else {
            throw AyuBridgeFailure("invalid_arguments", "Unsupported Typeface style")
        }
        guard style > 0 else { return TextViewTypeface(value: typeface, handle: reference?.handle) }
        let styled = (typeface ?? .default).styled(style)
        return TextViewTypeface(value: styled, handle: styled == typeface ? reference?.handle : nil)
    }
}

extension AyuBridgeJavaRuntime {
    private static func typefaceResult(_ value: AyuBridgeTypefaceValue?) -> AyuBridgeAdapterResult {
        guard let value else { return .value(.null) }
        return .instance(className: AyuBridgeTypefaceValue.className, state: value.state)
    }

    private static func typefacePreset(_ value: AyuBridgeTypefaceValue) -> AyuBridgeClassAdapter.StaticField {
        { _ in .instance(className: AyuBridgeTypefaceValue.className, state: value.state) }
    }

    private static func typefaceGetter(_ read: @escaping @Sendable (AyuBridgeTypefaceValue) -> AyuBridgeValue) -> AyuBridgeClassAdapter.InstanceMethod {
        { state, args, _ in
            guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Typeface getter takes no arguments") }
            return .value(read(try AyuBridgeTypefaceValue(state: state)))
        }
    }

    static var typeface: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.graphics.Typeface",
            constants: ["NORMAL": .integer(0), "BOLD": .integer(1), "ITALIC": .integer(2), "BOLD_ITALIC": .integer(3)],
            staticMethods: [
                "create": { args, context in
                    if args.count == 3 {
                        guard let weight = args[1].integer, let italic = args[2].bool else {
                            throw AyuBridgeFailure("invalid_arguments", "Typeface.create(family, weight, italic) expects an int and a boolean")
                        }
                        let family = try AyuBridgeTypefaceValue.argument(args[0], context: context) ?? .default
                        return Self.typefaceResult(try family.weighted(weight, italic: italic))
                    }
                    guard args.count == 2, let style = args[1].integer else {
                        throw AyuBridgeFailure("invalid_arguments", "Typeface.create expects a family and a style")
                    }
                    let family: AyuBridgeTypefaceValue
                    if let name = args[0].string {
                        family = try AyuBridgeTypefaceValue.family(name)
                    } else {
                        family = try AyuBridgeTypefaceValue.argument(args[0], context: context) ?? .default
                    }
                    return Self.typefaceResult(family.styled(style))
                },
                "defaultFromStyle": { args, _ in
                    guard args.count == 1, let style = args[0].integer, (0...3).contains(style) else {
                        throw AyuBridgeFailure("invalid_arguments", "Typeface.defaultFromStyle expects a style from 0 through 3")
                    }
                    return Self.typefaceResult(AyuBridgeTypefaceValue.default.styled(style))
                },
            ],
            staticFields: [
                "DEFAULT": Self.typefacePreset(.default),
                "DEFAULT_BOLD": Self.typefacePreset(AyuBridgeTypefaceValue.default.styled(1)),
                "SANS_SERIF": Self.typefacePreset(.default),
                "SERIF": Self.typefacePreset(AyuBridgeTypefaceValue(design: .serif, baseWeight: 400, weight: 400, style: 0)),
                "MONOSPACE": Self.typefacePreset(AyuBridgeTypefaceValue(design: .monospace, baseWeight: 400, weight: 400, style: 0)),
            ],
            methods: [
                "getStyle": Self.typefaceGetter { .integer($0.style) },
                "getWeight": Self.typefaceGetter { .integer($0.weight) },
                "isBold": Self.typefaceGetter { .bool($0.isBold) },
                "isItalic": Self.typefaceGetter { .bool($0.isItalic) },
            ],
            results: [
                "create": "android.graphics.Typeface", "defaultFromStyle": "android.graphics.Typeface",
                "DEFAULT": "android.graphics.Typeface", "DEFAULT_BOLD": "android.graphics.Typeface",
                "SANS_SERIF": "android.graphics.Typeface", "SERIF": "android.graphics.Typeface",
                "MONOSPACE": "android.graphics.Typeface",
            ],
            validateState: { _ = try AyuBridgeTypefaceValue(state: $0) })
    }

    /// `AndroidUtilities.bold()` and `getTypeface(assetPath)`, served by the application adapter.
    static let androidUtilitiesBold: AyuBridgeClassAdapter.StaticMethod = { args, _ in
        guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "AndroidUtilities.bold takes no arguments") }
        return typefaceResult(AyuBridgeTypefaceValue.asset("fonts/rmedium.ttf"))
    }

    static let androidUtilitiesGetTypeface: AyuBridgeClassAdapter.StaticMethod = { args, _ in
        guard args.count == 1, let path = args[0].string, path.utf8.count <= 1024 else {
            throw AyuBridgeFailure("invalid_arguments", "AndroidUtilities.getTypeface expects an asset path")
        }
        return typefaceResult(AyuBridgeTypefaceValue.asset(path))
    }
}
