import Foundation

/// The only storage values accepted by the source-pinned atmospheric plugin.
/// Arrays, objects, and non-finite numbers are intentionally unsupported.
public enum AtmosphericSettingValue: Equatable, Sendable, Codable {
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Atmospheric settings must be finite JSON primitives, not arrays or objects."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .boolean(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Non-finite atmospheric settings are unsupported."
                ))
            }
            try container.encode(value)
        case let .string(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// A settings request that cannot be represented by this pinned backend.
public enum AtmosphericSettingsError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedKey(String)
    case nonFiniteNumber(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedKey(key):
            return "Unsupported atmospheric_snow setting: \(key)."
        case let .nonFiniteNumber(key):
            return "Atmospheric setting \(key) must be a finite number."
        }
    }
}

/// A pure migration result. The host, not the renderer, persists these values.
public struct AtmosphericSettingsMigration: Equatable, Sendable {
    public let values: [String: AtmosphericSettingValue]
    public let didApplySnowDefaultsMigration: Bool
    /// The eight overwritten keys, in the source's write order; empty when already migrated.
    public let changedKeys: [String]
}

/// Source selector `snow_area` (only snowfall, not festive decoration, is filtered).
public enum AtmosphericSnowArea: Int, CaseIterable, Codable, Sendable {
    case everywhere = 0
    case chatsOnly = 1
    case chatListAndChats = 2

    public func includes(_ page: AtmosphericPageKind) -> Bool {
        switch self {
        case .everywhere: return true
        case .chatsOnly: return page == .chat || page == .lookupFailed
        case .chatListAndChats: return page == .chat || page == .chatList || page == .lookupFailed
        }
    }
}

/// Shared by navbar, glass pills, profile actions, avatar ring, and section cards.
public enum AtmosphericFestiveStyle: Int, CaseIterable, Codable, Sendable {
    case snowcapAndGarland = 0
    case frostAndIcicles = 1
    case warmGarland = 2
    case auroraAndSparkles = 3
}

/// Source garland palettes; bulbs do not blink in the pinned version.
public enum AtmosphericGarlandPalette: Int, CaseIterable, Codable, Sendable {
    case holidayMix = 0
    case warmGold = 1
    case icyNeon = 2
}

/// Exactly 26, 50, or 82 particles, independent of surface area.
public enum AtmosphericSnowDensity: Int, CaseIterable, Codable, Sendable {
    case light = 0
    case medium = 1
    case heavy = 2

    public var particleCount: Int {
        switch self {
        case .light: return 26
        case .medium: return 50
        case .heavy: return 82
        }
    }
}

/// Source downward-speed multipliers. Wind and sway are not multiplied by speed.
public enum AtmosphericSnowSpeed: Int, CaseIterable, Codable, Sendable {
    case slow = 0
    case normal = 1
    case fast = 2

    public var multiplier: Double {
        switch self {
        case .slow: return 0.6
        case .normal: return 1.0
        case .fast: return 1.55
        }
    }
}

/// Base horizontal wind in UIKit points/second (Android dp mapped to points).
public enum AtmosphericSnowWind: Int, CaseIterable, Codable, Sendable {
    case calm = 0
    case breeze = 1
    case blizzard = 2

    public var strength: Double {
        switch self {
        case .calm: return 0
        case .breeze: return 18
        case .blizzard: return 48
        }
    }
}

/// Background-layer particles remain grains even in the crystals-only selector.
public enum AtmosphericSnowStyle: Int, CaseIterable, Codable, Sendable {
    case bokeh = 0
    case crystals = 1
    case mixed = 2
}

/// Source particle-size presets, including the migrated 45% default.
public enum AtmosphericSnowSize: Int, CaseIterable, Codable, Sendable {
    case verySmall = 0
    case small = 1
    case normal = 2
    case large = 3
    case veryLarge = 4

    public var multiplier: Double {
        switch self {
        case .verySmall: return 0.45
        case .small: return 0.70
        case .normal: return 1.0
        case .large: return 1.35
        case .veryLarge: return 1.75
        }
    }
}

/// Source opacity multipliers; rendered alpha uses the source's eight buckets.
public enum AtmosphericSnowOpacity: Int, CaseIterable, Codable, Sendable {
    case barelyVisible = 0
    case translucent = 1
    case soft = 2
    case normal = 3
    case bright = 4

    public var multiplier: Double {
        switch self {
        case .barelyVisible: return 0.25
        case .translucent: return 0.50
        case .soft: return 0.75
        case .normal: return 1.0
        case .bright: return 1.35
        }
    }
}

/// Source snow colors. Automatic resolves from this view's UIKit traits.
public enum AtmosphericSnowColor: Int, CaseIterable, Codable, Sendable {
    case automatic = 0
    case white = 1
    case icyBlue = 2
    case warm = 3
}

/// Typed configuration of atmospheric_snow 1.0.1, not a generic effects renderer.
/// Dictionary initialization runs the exact first-load preset migration before reading settings.
public struct AtmosphericSnowConfiguration: Equatable, Sendable {
    public static let pluginIdentifier = "atmospheric_snow"
    public static let sourceVersion = "1.0.1"
    /// Supplied source pin; this implementation does not execute or import that file.
    public static let sourceSHA256 = "bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763"

    public var snowEnabled: Bool
    public var snowArea: AtmosphericSnowArea
    public var navbarFestiveEnabled: Bool
    public var glassPillsEnabled: Bool
    public var profileFestiveEnabled: Bool
    public var navbarStyle: AtmosphericFestiveStyle
    public var navbarGarlandPalette: AtmosphericGarlandPalette
    public var navbarActiveGlow: Bool
    public var snowDensity: AtmosphericSnowDensity
    public var snowSpeed: AtmosphericSnowSpeed
    public var snowWind: AtmosphericSnowWind
    public var snowStyle: AtmosphericSnowStyle
    public var snowSize: AtmosphericSnowSize
    public var snowOpacity: AtmosphericSnowOpacity
    public var snowColor: AtmosphericSnowColor
    /// Preserved migration marker, including versions greater than one; never used to animate.
    public private(set) var sourceDefaultsVersion: AtmosphericSettingValue

    /// Creates an already-migrated configuration with the source's exact selector defaults.
    public init(
        snowEnabled: Bool = true,
        snowArea: AtmosphericSnowArea = .everywhere,
        navbarFestiveEnabled: Bool = true,
        glassPillsEnabled: Bool = true,
        profileFestiveEnabled: Bool = true,
        navbarStyle: AtmosphericFestiveStyle = .snowcapAndGarland,
        navbarGarlandPalette: AtmosphericGarlandPalette = .holidayMix,
        navbarActiveGlow: Bool = true,
        snowDensity: AtmosphericSnowDensity = .medium,
        snowSpeed: AtmosphericSnowSpeed = .normal,
        snowWind: AtmosphericSnowWind = .breeze,
        snowStyle: AtmosphericSnowStyle = .mixed,
        snowSize: AtmosphericSnowSize = .verySmall,
        snowOpacity: AtmosphericSnowOpacity = .bright,
        snowColor: AtmosphericSnowColor = .automatic
    ) {
        self.snowEnabled = snowEnabled
        self.snowArea = snowArea
        self.navbarFestiveEnabled = navbarFestiveEnabled
        self.glassPillsEnabled = glassPillsEnabled
        self.profileFestiveEnabled = profileFestiveEnabled
        self.navbarStyle = navbarStyle
        self.navbarGarlandPalette = navbarGarlandPalette
        self.navbarActiveGlow = navbarActiveGlow
        self.snowDensity = snowDensity
        self.snowSpeed = snowSpeed
        self.snowWind = snowWind
        self.snowStyle = snowStyle
        self.snowSize = snowSize
        self.snowOpacity = snowOpacity
        self.snowColor = snowColor
        self.sourceDefaultsVersion = .integer(1)
    }

    /// Rejects unknown keys rather than silently advertising unsupported settings.
    /// Selectors use Python `int(value)` coercion and per-key fallback, not clamping.
    /// Switches use Python truthiness: for example, the nonempty string "false" is true.
    public init(settings: [String: AtmosphericSettingValue]) throws {
        let values = try Self.migrateSettings(settings).values
        self.init(
            snowEnabled: Self.readSwitch(values, "snow_enabled"),
            snowArea: Self.readSelector(values, "snow_area", default: .everywhere),
            navbarFestiveEnabled: Self.readSwitch(values, "navbar_festive_enabled"),
            glassPillsEnabled: Self.readSwitch(values, "glass_pills_enabled"),
            profileFestiveEnabled: Self.readSwitch(values, "profile_festive_enabled"),
            navbarStyle: Self.readSelector(values, "navbar_style", default: .snowcapAndGarland),
            navbarGarlandPalette: Self.readSelector(values, "navbar_garland_palette", default: .holidayMix),
            navbarActiveGlow: Self.readSwitch(values, "navbar_active_glow"),
            snowDensity: Self.readSelector(values, "snow_density", default: .medium),
            snowSpeed: Self.readSelector(values, "snow_speed", default: .normal),
            snowWind: Self.readSelector(values, "snow_wind", default: .breeze),
            snowStyle: Self.readSelector(values, "snow_style", default: .mixed),
            snowSize: Self.readSelector(values, "snow_size", default: .verySmall),
            snowOpacity: Self.readSelector(values, "snow_opacity", default: .bright),
            snowColor: Self.readSelector(values, "snow_color", default: .automatic)
        )
        sourceDefaultsVersion = values["snow_defaults_v"] ?? .integer(1)
    }

    /// Returns source-keyed primitives for persistence; never called on the animation path.
    public var settings: [String: AtmosphericSettingValue] {
        return [
            "snow_enabled": .boolean(snowEnabled),
            "snow_area": .integer(snowArea.rawValue),
            "navbar_festive_enabled": .boolean(navbarFestiveEnabled),
            "glass_pills_enabled": .boolean(glassPillsEnabled),
            "profile_festive_enabled": .boolean(profileFestiveEnabled),
            "navbar_style": .integer(navbarStyle.rawValue),
            "navbar_garland_palette": .integer(navbarGarlandPalette.rawValue),
            "navbar_active_glow": .boolean(navbarActiveGlow),
            "snow_density": .integer(snowDensity.rawValue),
            "snow_speed": .integer(snowSpeed.rawValue),
            "snow_wind": .integer(snowWind.rawValue),
            "snow_style": .integer(snowStyle.rawValue),
            "snow_size": .integer(snowSize.rawValue),
            "snow_opacity": .integer(snowOpacity.rawValue),
            "snow_color": .integer(snowColor.rawValue),
            "snow_defaults_v": sourceDefaultsVersion
        ]
    }

    /// Source lines 384–399: missing, malformed, zero, or negative versions overwrite
    /// density/speed/wind/style/size/opacity/color, even if those settings already exist.
    /// A version whose Python integer value is >= 1 is left completely untouched.
    public static func migrateSettings(
        _ settings: [String: AtmosphericSettingValue]
    ) throws -> AtmosphericSettingsMigration {
        for key in settings.keys.sorted() {
            guard supportedKeys.contains(key) else { throw AtmosphericSettingsError.unsupportedKey(key) }
            if case let .number(number)? = settings[key], !number.isFinite {
                throw AtmosphericSettingsError.nonFiniteNumber(key)
            }
        }
        if pythonInteger(settings["snow_defaults_v"]).isAtLeastOne {
            return .init(values: settings, didApplySnowDefaultsMigration: false, changedKeys: [])
        }
        var result = settings
        for (key, value) in migratedPresets { result[key] = .integer(value) }
        return .init(
            values: result,
            didApplySnowDefaultsMigration: true,
            changedKeys: migratedPresets.map { $0.0 }
        )
    }

    /// The 15 source settings and its migration marker. No intensity or per-surface style aliases.
    public static let supportedKeys: Set<String> = [
        "snow_enabled", "snow_area", "navbar_festive_enabled", "glass_pills_enabled",
        "profile_festive_enabled", "navbar_style", "navbar_garland_palette", "navbar_active_glow",
        "snow_density", "snow_speed", "snow_wind", "snow_style", "snow_size", "snow_opacity",
        "snow_color", "snow_defaults_v"
    ]

    private static let migratedPresets: [(String, Int)] = [
        ("snow_density", 1), ("snow_speed", 1), ("snow_wind", 1), ("snow_style", 2),
        ("snow_size", 0), ("snow_opacity", 4), ("snow_color", 0), ("snow_defaults_v", 1)
    ]

    private static func readSwitch(_ settings: [String: AtmosphericSettingValue], _ key: String) -> Bool {
        guard let value = settings[key] else { return true }
        switch value {
        case let .boolean(value): return value
        case let .integer(value): return value != 0
        case let .number(value): return value != 0
        case let .string(value): return !value.isEmpty
        case .null: return false
        }
    }

    private static func readSelector<Selector: RawRepresentable>(
        _ settings: [String: AtmosphericSettingValue],
        _ key: String,
        default fallback: Selector
    ) -> Selector where Selector.RawValue == Int {
        guard case let .value(index) = pythonInteger(settings[key]) else { return fallback }
        return Selector(rawValue: index) ?? fallback
    }
}

// Python integers are unbounded. Overflowing selector values still fall back, but a
// positive overflowing migration version must NOT accidentally trigger migration.
private enum AtmosphericPythonInteger {
    case value(Int)
    case positiveOverflow
    case negativeOverflow
    case invalid

    var isAtLeastOne: Bool {
        switch self {
        case let .value(value): return value >= 1
        case .positiveOverflow: return true
        case .negativeOverflow, .invalid: return false
        }
    }
}

private func pythonInteger(_ value: AtmosphericSettingValue?) -> AtmosphericPythonInteger {
    guard let value else { return .invalid }
    switch value {
    case let .integer(value): return .value(value)
    case let .boolean(value): return .value(value ? 1 : 0)
    case let .number(value):
        guard value.isFinite else { return .invalid }
        if let integer = Int(exactly: value.rounded(.towardZero)) { return .value(integer) }
        return value > 0 ? .positiveOverflow : .negativeOverflow
    case .null: return .invalid
    case let .string(value): return parsePythonDecimalInteger(value)
    }
}

private func parsePythonDecimalInteger(_ string: String) -> AtmosphericPythonInteger {
    let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .invalid }
    var negative = false
    var first = true
    var hasDigit = false
    var previousWasDigit = false
    var overflow = false
    // Accumulate negatively to support Int.min without an intermediate positive overflow.
    var accumulator = 0
    for character in text {
        if first {
            first = false
            if character == "+" { continue }
            if character == "-" { negative = true; continue }
        }
        if character == "_" {
            guard previousWasDigit else { return .invalid }
            previousWasDigit = false
            continue
        }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.properties.generalCategory == .decimalNumber,
              let digit = character.wholeNumberValue, digit <= 9 else { return .invalid }
        hasDigit = true
        previousWasDigit = true
        if !overflow {
            let product = accumulator.multipliedReportingOverflow(by: 10)
            let next = product.partialValue.subtractingReportingOverflow(digit)
            overflow = product.overflow || next.overflow
            accumulator = next.partialValue
        }
    }
    guard hasDigit, previousWasDigit else { return .invalid }
    if overflow { return negative ? .negativeOverflow : .positiveOverflow }
    if negative { return .value(accumulator) }
    if accumulator == Int.min { return .positiveOverflow }
    return .value(-accumulator)
}
