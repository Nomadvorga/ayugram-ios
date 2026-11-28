import CryptoKit
import Foundation
import AyuAtmosphericHost
import AyuAtmosphericSnow

/// Native, source-pinned compatibility route for @coshize's Atmospheric Snow 1.0.1.
/// It translates the known source contract; it never executes or emulates arbitrary Android code.
@MainActor final class AyuAtmosphericPluginAdapter {
    nonisolated static let pluginID = "atmospheric_snow"
    nonisolated static let adapterID = "atmospheric_snow.native.v1"
    nonisolated static let sourceSHA256 = "bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763"
    private let defaults: UserDefaults
    private let reportError: ((String?) -> Void)?
    private let state = AyuAtmosphericRenderingState()
    private var isEnabled = false
    private var generation: UUID?
    private var ownsGeneration: Bool { self.isEnabled && self.generation != nil && self.generation == AtmosphericHost.shared.generation }
    private var storageKey: String { "AyuPluginBridge.v1." + Self.pluginID }

    init(defaults: UserDefaults, reportError: ((String?) -> Void)? = nil) {
        self.defaults = defaults
        self.reportError = reportError
        self.state.reportError = reportError
    }

    isolated deinit {
        if self.generation != nil && self.generation == AtmosphericHost.shared.generation { AtmosphericHost.shared.disable() }
        self.state.clear()
    }

    nonisolated static func matchesSource(_ source: Data) -> Bool {
        source.count <= 1_048_576 && SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined() == Self.sourceSHA256
    }

    nonisolated static func record(for source: Data) -> AyuInstalledPlugin? {
        guard Self.matchesSource(source) else { return nil }
        return AyuInstalledPlugin(id: Self.pluginID, name: "NewYear Interface", version: "1.0.1", blockers: [], nativeAdapter: Self.adapterID)
    }

    func enable() throws {
        var values = try self.loadValues()
        self.state.reportError = self.reportError
        // Source L384-L401: marker <1 overwrites the seven existing snow selectors.
        let migration = try AtmosphericSnowConfiguration.migrateSettings(AyuAtmosphericRenderingState.convert(Self.normalized(values)))
        if migration.didApplySnowDefaultsMigration {
            for definition in Self.definitions where Self.migrationKeys.contains(definition.key) { values[definition.key] = definition.defaultValue }
            values["snow_defaults_v"] = .integer(1)
            try self.saveValues(values)
        }
        try self.state.apply(values: Self.normalized(values))
        let state = self.state
        AtmosphericHost.shared.enable { role in AyuAtmosphericRendering(state: state, role: role) }
        self.generation = AtmosphericHost.shared.generation
        self.isEnabled = true
    }

    func disable() {
        self.isEnabled = false
        if self.generation != nil && self.generation == AtmosphericHost.shared.generation { AtmosphericHost.shared.disable() }
        self.generation = nil
        self.state.clear()
    }

    func settings() throws -> [AyuPluginSetting] {
        let values = try Self.normalized(self.loadValues())
        var rows: [AyuPluginSetting] = []
        for (index, definition) in Self.definitions.enumerated() {
            if let heading = Self.headings[index] {
                if index > 0 { rows.append(Self.textRow(type: "Divider", text: "")) }
                rows.append(Self.textRow(type: "Header", text: heading))
            }
            var descriptor: [String: AyuBridgeValue] = [
                "type": .string(definition.choices.isEmpty ? "Switch" : "Selector"),
                "key": .string(definition.key), "text": .string(definition.label),
                "subtext": .string(definition.subtext), "default": definition.defaultValue,
                "native_generation": .string(self.generation?.uuidString ?? ""),
            ]
            if !definition.choices.isEmpty { descriptor["items"] = .array(definition.choices.map(AyuBridgeValue.string)) }
            rows.append(AyuPluginSetting(descriptor: .object(descriptor), value: values[definition.key] ?? definition.defaultValue))
        }
        rows.append(Self.textRow(type: "Divider", text: ""))
        rows.append(Self.textRow(type: "Text", text: "NewYear Interface v1.0.1", subtext: "Новогоднее оформление интерфейса · @coshize · нативный адаптер iOS"))
        if let error = self.state.renderingError {
            rows.append(Self.textRow(type: "Text", text: "Ошибка", subtext: String(error.prefix(120))))
        }
        var reset = Self.textRow(type: "Text", text: "Сбросить настройки", subtext: "Дополнительная функция iOS: исходные defaults 45% размера и 135% яркости.", action: "reset")
        if var descriptor = reset.descriptor.object {
            descriptor["native_generation"] = .string(self.generation?.uuidString ?? "")
            reset = AyuPluginSetting(descriptor: .object(descriptor), value: .null)
        }
        rows.append(reset)
        return rows
    }

    func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.ownsGeneration else { throw AyuPluginService.Failure.inactive }
        guard row.descriptor["native_generation"].string == self.generation?.uuidString else { throw AyuPluginService.Failure.inactive }
        guard let key = row.key, let definition = Self.definitions.first(where: { $0.key == key }) else { throw AyuPluginService.Failure.protocolError }
        if definition.choices.isEmpty {
            guard case .bool = value else { throw AyuPluginService.Failure.operation("INVALID_SETTING_TYPE") }
        } else {
            guard let index = value.integer, index >= 0, index < Int64(definition.choices.count) else { throw AyuPluginService.Failure.operation("INVALID_SETTING_INDEX") }
        }
        var values = try self.loadValues()
        values[key] = value
        let snapshot = try Self.normalized(values)
        try self.saveValues(values)
        try self.state.apply(values: snapshot)
        AtmosphericHost.shared.refresh()
    }

    func activate(_ row: AyuPluginSetting) throws {
        guard self.ownsGeneration else { throw AyuPluginService.Failure.inactive }
        guard let action = row.descriptor["native_action"].string else { return }
        guard row.descriptor["native_generation"].string == self.generation?.uuidString else { throw AyuPluginService.Failure.inactive }
        guard action == "reset" else { throw AyuPluginService.Failure.operation("UNSUPPORTED_NATIVE_ACTION") }
        var values = try self.loadValues()
        for definition in Self.definitions { values[definition.key] = definition.defaultValue }
        values["snow_defaults_v"] = .integer(1)
        try self.saveValues(values)
        try self.state.apply(values: Self.normalized(values))
        AtmosphericHost.shared.refresh()
    }

    private func loadValues() throws -> [String: AyuBridgeValue] {
        guard let data = self.defaults.data(forKey: self.storageKey) else { return [:] }
        guard data.count <= 65_536 else { throw AyuPluginService.Failure.operation("SETTINGS_QUOTA") }
        do { return try JSONDecoder().decode([String: AyuBridgeValue].self, from: data) }
        catch { throw AyuPluginService.Failure.protocolError }
    }

    private func saveValues(_ values: [String: AyuBridgeValue]) throws {
        let data = try JSONEncoder().encode(values)
        guard data.count <= 65_536 else { throw AyuPluginService.Failure.operation("SETTINGS_QUOTA") }
        self.defaults.set(data, forKey: self.storageKey)
    }

    private struct Definition {
        let key: String
        let label: String
        var subtext: String = ""
        var choices: [String] = []
        var defaultIndex: Int = 0
        var defaultValue: AyuBridgeValue { self.choices.isEmpty ? .bool(true) : .integer(Int64(self.defaultIndex)) }
    }

    private static let migrationKeys: Set<String> = ["snow_density", "snow_speed", "snow_wind", "snow_style", "snow_size", "snow_opacity", "snow_color"]
    private static let headings = [0: "Основные настройки", 2: "Новогоднее оформление интерфейса", 8: "Атмосфера и физика снега", 11: "Внешний вид снега"]
    private static let definitions: [Definition] = [
        Definition(key: "snow_enabled", label: "Включить снег", subtext: "Отображает падающий снег поверх интерфейса"),
        Definition(key: "snow_area", label: "Где показывать", choices: ["Везде", "Только в чатах", "Список чатов и чаты"]),
        Definition(key: "navbar_festive_enabled", label: "Нижняя панель", subtext: "Сугробы, гирлянда и морозное свечение на главной панели"),
        Definition(key: "glass_pills_enabled", label: "Кнопки, папки, ввод и шапка", subtext: "Кнопки (←, поиск, меню), поле сообщения, папки и вкладки профиля"),
        Definition(key: "profile_festive_enabled", label: "Профиль: кнопки, аватар и окна", subtext: "Обводка аватара, больших кнопок и всех карточек профиля"),
        Definition(key: "navbar_style", label: "Новогодний стиль кнопок и панели", choices: ["Снежная шапка + гирлянда", "Морозная (лёд и сосульки)", "Тёплая гирлянда", "Северное сияние и искры"]),
        Definition(key: "navbar_garland_palette", label: "Цвета гирлянды", choices: ["Новогоднее ассорти", "Тёплое золото", "Ледяной неон"]),
        Definition(key: "navbar_active_glow", label: "Сияние и морозные искры", subtext: "Подсвечивает активную вкладку и добавляет искры на кнопки"),
        Definition(key: "snow_density", label: "Плотность снегопада", choices: ["Лёгкий", "Средний", "Сильный"], defaultIndex: 1),
        Definition(key: "snow_speed", label: "Скорость падения", choices: ["Медленно", "Обычно", "Быстро"], defaultIndex: 1),
        Definition(key: "snow_wind", label: "Ветер", choices: ["Штиль", "Лёгкий бриз", "Метель"], defaultIndex: 1),
        Definition(key: "snow_style", label: "Стиль снежинок", choices: ["Боке (мягкое свечение)", "Снежинки", "Смешанный"], defaultIndex: 2),
        Definition(key: "snow_size", label: "Размер частиц и снежинок", choices: ["Очень мелкий (45%)", "Мелкий (70%)", "Обычный (100%)", "Крупный (135%)", "Очень крупный (175%)"]),
        Definition(key: "snow_opacity", label: "Прозрачность снега", choices: ["Едва заметный (25%)", "Полупрозрачный (50%)", "Мягкий (75%)", "Обычный (100%)", "Яркий (135%)"], defaultIndex: 4),
        Definition(key: "snow_color", label: "Цвет снега", choices: ["Авто (по теме)", "Белый", "Ледяной голубой", "Тёплый новогодний"]),
    ]

    private static func textRow(type: String, text: String, subtext: String = "", action: String? = nil) -> AyuPluginSetting {
        var descriptor: [String: AyuBridgeValue] = ["type": .string(type), "text": .string(text), "subtext": .string(subtext)]
        if let action { descriptor["native_action"] = .string(action) }
        return AyuPluginSetting(descriptor: .object(descriptor), value: .null)
    }

    private static func normalized(_ values: [String: AyuBridgeValue]) throws -> [String: AyuBridgeValue] {
        var primitive: [String: AyuBridgeValue] = [:]
        for definition in Self.definitions {
            guard let value = values[definition.key] else { continue }
            if definition.choices.isEmpty { primitive[definition.key] = .bool(Self.sourceBool(value)) }
            else if case .array = value { primitive[definition.key] = .null }
            else if case .object = value { primitive[definition.key] = .null }
            else { primitive[definition.key] = value }
        }
        // Settings display must not perform the first-enable migration. Reuse the backend's
        // Python int coercion (Unicode decimal digits, underscores, arbitrary-size markers).
        primitive["snow_defaults_v"] = .integer(1)
        let configuration = try AtmosphericSnowConfiguration(settings: AyuAtmosphericRenderingState.convert(primitive))
        var result: [String: AyuBridgeValue] = [:]
        for (key, value) in configuration.settings {
            switch value {
            case let .boolean(value): result[key] = .bool(value)
            case let .integer(value): result[key] = .integer(Int64(value))
            case let .number(value): result[key] = .number(value)
            case let .string(value): result[key] = .string(value)
            case .null: result[key] = .null
            }
        }
        let marker = values["snow_defaults_v"] ?? .null
        switch marker {
        case .array, .object: result["snow_defaults_v"] = .null
        default: result["snow_defaults_v"] = marker
        }
        return result
    }

    private static func sourceBool(_ value: AyuBridgeValue) -> Bool {
        switch value {
        case .null: return false
        case let .bool(value): return value
        case let .integer(value): return value != 0
        case let .number(value): return value != 0
        case let .string(value): return !value.isEmpty
        case let .array(value): return !value.isEmpty
        case let .object(value): return !value.isEmpty
        }
    }

}
