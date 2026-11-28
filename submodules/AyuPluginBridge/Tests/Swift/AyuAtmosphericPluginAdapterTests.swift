import Foundation
import XCTest
@testable import AyuPluginBridge

final class AyuAtmosphericPluginAdapterTests: XCTestCase {
    func testClaimedIdentityAloneNeverSelectsNativeAdapter() {
        let forged = Data("__id__ = 'atmospheric_snow'\n__version__ = '1.0.1'\n".utf8)
        XCTAssertFalse(AyuAtmosphericPluginAdapter.matchesSource(forged))
        XCTAssertNil(AyuAtmosphericPluginAdapter.record(for: forged))
        XCTAssertFalse(AyuAtmosphericPluginAdapter.matchesSource(Data()))
    }

    @MainActor func testExactSourceCatalogDefaultsWithoutExecutingPlugin() throws {
        let suite = "AyuAtmosphericAdapterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = AyuAtmosphericPluginAdapter(defaults: defaults)
        let rows = try adapter.settings()
        let keyed = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.key.map { ($0, row) } })
        XCTAssertEqual(keyed.count, 15)
        XCTAssertEqual(keyed["snow_density"]?.value, .integer(1))
        XCTAssertEqual(keyed["snow_style"]?.value, .integer(2))
        XCTAssertEqual(keyed["snow_size"]?.value, .integer(0))
        XCTAssertEqual(keyed["snow_opacity"]?.value, .integer(4))
        XCTAssertEqual(keyed["snow_enabled"]?.value, .bool(true))
        XCTAssertEqual(keyed["profile_festive_enabled"]?.value, .bool(true))
        XCTAssertNil(keyed["snow_defaults_v"])
        XCTAssertNil(keyed["glass_style"])
        XCTAssertEqual(keyed["navbar_style"]?.descriptor["items"].array?.count, 4)
        XCTAssertEqual(keyed["navbar_garland_palette"]?.descriptor["items"].array?.count, 3)
    }

    @MainActor func testLegacyValuesUseSourceFallbackAndTruthiness() throws {
        let suite = "AyuAtmosphericAdapterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: AyuBridgeValue] = [
            "snow_size": .integer(-1), "snow_opacity": .integer(99),
            "snow_speed": .number(1.9), "snow_enabled": .string("false"),
            "glass_pills_enabled": .null,
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "AyuPluginBridge.v1.atmospheric_snow")
        let rows = try AyuAtmosphericPluginAdapter(defaults: defaults).settings()
        let values = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.key.map { ($0, row.value) } })
        XCTAssertEqual(values["snow_size"], .integer(0))
        XCTAssertEqual(values["snow_opacity"], .integer(4))
        XCTAssertEqual(values["snow_speed"], .integer(1))
        XCTAssertEqual(values["snow_enabled"], .bool(true))
        XCTAssertEqual(values["glass_pills_enabled"], .bool(false))
    }

    @MainActor func testMigrationResetsOnlySevenSnowSelectorsAndRetainsOtherPreferences() throws {
        let suite = "AyuAtmosphericAdapterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = "AyuPluginBridge.v1.atmospheric_snow"
        let legacy: [String: AyuBridgeValue] = ["snow_size": .integer(4), "snow_opacity": .integer(0),
                                              "snow_enabled": .bool(false), "navbar_style": .integer(3)]
        defaults.set(try JSONEncoder().encode(legacy), forKey: storage)
        let adapter = AyuAtmosphericPluginAdapter(defaults: defaults)
        try adapter.enable()
        defer { adapter.disable() }
        let persisted = try JSONDecoder().decode([String: AyuBridgeValue].self, from: XCTUnwrap(defaults.data(forKey: storage)))
        XCTAssertEqual(persisted["snow_size"], .integer(0))
        XCTAssertEqual(persisted["snow_opacity"], .integer(4))
        XCTAssertEqual(persisted["snow_style"], .integer(2))
        XCTAssertEqual(persisted["snow_defaults_v"], .integer(1))
        XCTAssertEqual(persisted["snow_enabled"], .bool(false))
        XCTAssertEqual(persisted["navbar_style"], .integer(3))
    }

    @MainActor func testPositiveOverflowMarkerDoesNotTriggerMigration() throws {
        let suite = "AyuAtmosphericAdapterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = "AyuPluginBridge.v1.atmospheric_snow"
        let values: [String: AyuBridgeValue] = ["snow_defaults_v": .string("999999999999999999999999999999999999"),
                                               "snow_size": .integer(4), "snow_speed": .string("+١_٠")]
        let original = try JSONEncoder().encode(values)
        defaults.set(original, forKey: storage)
        let adapter = AyuAtmosphericPluginAdapter(defaults: defaults)
        try adapter.enable()
        defer { adapter.disable() }
        XCTAssertEqual(defaults.data(forKey: storage), original)
        let rows = try adapter.settings()
        XCTAssertEqual(rows.first { $0.key == "snow_size" }?.value, .integer(4))
        // Python int('+١_٠') == 10; out-of-range selectors use the source fallback.
        XCTAssertEqual(rows.first { $0.key == "snow_speed" }?.value, .integer(1))
    }

    @MainActor func testOldSettingsRowsCannotMutateNewGeneration() throws {
        let suite = "AyuAtmosphericAdapterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = AyuAtmosphericPluginAdapter(defaults: defaults)
        try adapter.enable()
        let stale = try XCTUnwrap(adapter.settings().first { $0.key == "snow_enabled" })
        adapter.disable()
        try adapter.enable()
        defer { adapter.disable() }
        XCTAssertThrowsError(try adapter.set(stale, value: .bool(false)))
        let current = try XCTUnwrap(adapter.settings().first { $0.key == "snow_enabled" })
        try adapter.set(current, value: .bool(false))
        XCTAssertEqual(try adapter.settings().first { $0.key == "snow_enabled" }?.value, .bool(false))
    }
}
