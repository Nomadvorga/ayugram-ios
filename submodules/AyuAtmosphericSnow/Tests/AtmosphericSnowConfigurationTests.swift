import Foundation
import XCTest
@testable import AyuAtmosphericSnow

final class AtmosphericSnowConfigurationTests: XCTestCase {
    func testDefaultsAndSourceKeys() throws {
        let configuration = try AtmosphericSnowConfiguration(settings: [:])
        XCTAssertEqual(configuration, AtmosphericSnowConfiguration())
        XCTAssertTrue(configuration.snowEnabled)
        XCTAssertTrue(configuration.navbarFestiveEnabled)
        XCTAssertTrue(configuration.glassPillsEnabled)
        XCTAssertTrue(configuration.profileFestiveEnabled)
        XCTAssertTrue(configuration.navbarActiveGlow)
        XCTAssertEqual(configuration.snowArea, .everywhere)
        XCTAssertEqual(configuration.navbarStyle, .snowcapAndGarland)
        XCTAssertEqual(configuration.navbarGarlandPalette, .holidayMix)
        XCTAssertEqual(configuration.snowDensity.particleCount, 50)
        XCTAssertEqual(configuration.snowSpeed.multiplier, 1)
        XCTAssertEqual(configuration.snowWind.strength, 18)
        XCTAssertEqual(configuration.snowStyle, .mixed)
        XCTAssertEqual(configuration.snowSize.multiplier, 0.45)
        XCTAssertEqual(configuration.snowOpacity.multiplier, 1.35)
        XCTAssertEqual(configuration.snowColor, .automatic)
        XCTAssertEqual(Set(configuration.settings.keys), AtmosphericSnowConfiguration.supportedKeys)
        XCTAssertEqual(configuration.settings.count, 16)
    }

    func testEveryPhysicalPresetAndRawSelectorIndex() {
        XCTAssertEqual(AtmosphericSnowDensity.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(AtmosphericSnowDensity.allCases.map(\.particleCount), [26, 50, 82])
        XCTAssertEqual(AtmosphericSnowSpeed.allCases.map(\.multiplier), [0.6, 1, 1.55])
        XCTAssertEqual(AtmosphericSnowWind.allCases.map(\.strength), [0, 18, 48])
        XCTAssertEqual(AtmosphericSnowSize.allCases.map(\.multiplier), [0.45, 0.70, 1, 1.35, 1.75])
        XCTAssertEqual(AtmosphericSnowOpacity.allCases.map(\.multiplier), [0.25, 0.50, 0.75, 1, 1.35])
        XCTAssertEqual(AtmosphericSnowArea.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(AtmosphericFestiveStyle.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(AtmosphericGarlandPalette.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(AtmosphericSnowStyle.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(AtmosphericSnowColor.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    func testMigrationOverwritesOnlyTheSevenPresetsAndMarker() throws {
        let original: [String: AtmosphericSettingValue] = [
            "snow_enabled": .boolean(false), "snow_area": .integer(2),
            "navbar_style": .integer(3), "navbar_garland_palette": .integer(2),
            "snow_density": .integer(2), "snow_speed": .integer(2), "snow_wind": .integer(0),
            "snow_style": .integer(0), "snow_size": .integer(4), "snow_opacity": .integer(0),
            "snow_color": .integer(3)
        ]
        let result = try AtmosphericSnowConfiguration.migrateSettings(original)
        XCTAssertTrue(result.didApplySnowDefaultsMigration)
        XCTAssertEqual(result.changedKeys, ["snow_density", "snow_speed", "snow_wind", "snow_style",
                                            "snow_size", "snow_opacity", "snow_color", "snow_defaults_v"])
        XCTAssertEqual(result.values["snow_density"], .integer(1))
        XCTAssertEqual(result.values["snow_speed"], .integer(1))
        XCTAssertEqual(result.values["snow_wind"], .integer(1))
        XCTAssertEqual(result.values["snow_style"], .integer(2))
        XCTAssertEqual(result.values["snow_size"], .integer(0))
        XCTAssertEqual(result.values["snow_opacity"], .integer(4))
        XCTAssertEqual(result.values["snow_color"], .integer(0))
        XCTAssertEqual(result.values["snow_defaults_v"], .integer(1))
        XCTAssertEqual(result.values["snow_enabled"], original["snow_enabled"])
        XCTAssertEqual(result.values["snow_area"], original["snow_area"])
        XCTAssertEqual(result.values["navbar_style"], original["navbar_style"])
        XCTAssertEqual(result.values["navbar_garland_palette"], original["navbar_garland_palette"])
        XCTAssertNil(original["snow_defaults_v"], "Migration must not mutate the caller's dictionary")
        XCTAssertFalse(try AtmosphericSnowConfiguration.migrateSettings(result.values).didApplySnowDefaultsMigration)
    }

    func testMigrationVersionUsesPythonIntegerCoercionAndPreservesFutureMarker() throws {
        let oldMarkers: [AtmosphericSettingValue] = [.null, .integer(-1), .number(0.99), .string("bad"), .boolean(false)]
        for marker in oldMarkers {
            let result = try AtmosphericSnowConfiguration.migrateSettings(["snow_defaults_v": marker])
            XCTAssertTrue(result.didApplySnowDefaultsMigration)
        }
        let migratedMarkers: [AtmosphericSettingValue] = [.integer(1), .number(1.9), .string(" +2 "), .boolean(true),
                                                         .string("99999999999999999999999999999999")]
        for marker in migratedMarkers {
            let values: [String: AtmosphericSettingValue] = ["snow_defaults_v": marker, "snow_size": .integer(4)]
            let result = try AtmosphericSnowConfiguration.migrateSettings(values)
            XCTAssertFalse(result.didApplySnowDefaultsMigration)
            XCTAssertEqual(result.values, values)
            let configuration = try AtmosphericSnowConfiguration(settings: values)
            XCTAssertEqual(configuration.snowSize, .veryLarge)
            XCTAssertEqual(configuration.sourceDefaultsVersion, marker)
        }
    }

    func testInvalidSelectorsFallBackPerKeyInsteadOfClamping() throws {
        let configuration = try AtmosphericSnowConfiguration(settings: [
            "snow_defaults_v": .integer(1), "snow_area": .integer(-1), "navbar_style": .integer(99),
            "navbar_garland_palette": .null, "snow_density": .integer(99), "snow_speed": .string("1.5"),
            "snow_wind": .integer(-1), "snow_style": .string("bad"), "snow_size": .integer(5),
            "snow_opacity": .integer(-1), "snow_color": .string("0x2")
        ])
        XCTAssertEqual(configuration.snowArea, .everywhere)
        XCTAssertEqual(configuration.navbarStyle, .snowcapAndGarland)
        XCTAssertEqual(configuration.navbarGarlandPalette, .holidayMix)
        XCTAssertEqual(configuration.snowDensity, .medium)
        XCTAssertEqual(configuration.snowSpeed, .normal)
        XCTAssertEqual(configuration.snowWind, .breeze)
        XCTAssertEqual(configuration.snowStyle, .mixed)
        XCTAssertEqual(configuration.snowSize, .verySmall)
        XCTAssertEqual(configuration.snowOpacity, .bright)
        XCTAssertEqual(configuration.snowColor, .automatic)
    }

    func testSelectorCoercionAndSwitchTruthiness() throws {
        let configuration = try AtmosphericSnowConfiguration(settings: [
            "snow_defaults_v": .integer(1), "snow_area": .string(" ٢ "),
            "snow_speed": .string("+2"), "snow_wind": .number(2.9), "snow_color": .boolean(true),
            "snow_opacity": .number(-0.2), "snow_size": .string("1_0"),
            "snow_enabled": .string("false"), "navbar_festive_enabled": .null,
            "glass_pills_enabled": .integer(-2), "profile_festive_enabled": .string(""),
            "navbar_active_glow": .number(0)
        ])
        XCTAssertEqual(configuration.snowArea, .chatListAndChats)
        XCTAssertEqual(configuration.snowSpeed, .fast)
        XCTAssertEqual(configuration.snowWind, .blizzard)
        XCTAssertEqual(configuration.snowColor, .white)
        XCTAssertEqual(configuration.snowOpacity, .barelyVisible)
        XCTAssertEqual(configuration.snowSize, .verySmall)
        XCTAssertTrue(configuration.snowEnabled, "Source bool(nonempty string) is true")
        XCTAssertFalse(configuration.navbarFestiveEnabled)
        XCTAssertTrue(configuration.glassPillsEnabled)
        XCTAssertFalse(configuration.profileFestiveEnabled)
        XCTAssertFalse(configuration.navbarActiveGlow)
    }

    func testUnsupportedSettingsAndNonFiniteNumbersFailExplicitly() throws {
        for key in ["intensity", "glass_style", "profile_style", "collision_mask"] {
            XCTAssertThrowsError(try AtmosphericSnowConfiguration(settings: [key: .integer(1)])) {
                XCTAssertEqual($0 as? AtmosphericSettingsError, .unsupportedKey(key))
            }
        }
        XCTAssertThrowsError(try AtmosphericSnowConfiguration(settings: ["snow_speed": .number(.infinity)])) {
            XCTAssertEqual($0 as? AtmosphericSettingsError, .nonFiniteNumber("snow_speed"))
        }
    }

    func testCodablePrimitivesRejectObjectsAndArrays() throws {
        let values: [String: AtmosphericSettingValue] = [
            "b": .boolean(true), "i": .integer(2), "n": .number(2.75), "s": .string("x"), "null": .null
        ]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([String: AtmosphericSettingValue].self, from: data), values)
        for text in ["{\"snow_area\":{\"index\":1}}", "{\"snow_area\":[1]}"] {
            XCTAssertThrowsError(try JSONDecoder().decode([String: AtmosphericSettingValue].self, from: Data(text.utf8)))
        }
        XCTAssertThrowsError(try JSONEncoder().encode(AtmosphericSettingValue.number(.nan)))
    }

    func testAreaDoesNotInventAnAndroidControllerLookup() {
        XCTAssertTrue(AtmosphericSnowArea.everywhere.includes(.unavailable))
        XCTAssertTrue(AtmosphericSnowArea.chatsOnly.includes(.chat))
        XCTAssertFalse(AtmosphericSnowArea.chatsOnly.includes(.chatList))
        XCTAssertFalse(AtmosphericSnowArea.chatListAndChats.includes(.profile))
        XCTAssertFalse(AtmosphericSnowArea.chatListAndChats.includes(.unavailable))
        XCTAssertTrue(AtmosphericSnowArea.chatListAndChats.includes(.lookupFailed))
    }
}
