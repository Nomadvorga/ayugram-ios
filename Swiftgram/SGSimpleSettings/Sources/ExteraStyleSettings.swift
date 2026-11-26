import Foundation

/// Device-wide opt-in settings presentation. Hosts map these values into their renderer;
/// the settings row module never reads the store. Energy/accessibility gates remain external.
public final class ExteraStyleSettings: @unchecked Sendable {
    public enum ControlStyle: Int, CaseIterable {
        case classic = 0
        case material = 1
    }

    public enum SeparatorStyle: String, CaseIterable {
        case line
        case fullWidth
        case none
    }

    public enum GlassBorder: String, CaseIterable {
        case none
        case line
        case highlights
    }

    public static let shared = ExteraStyleSettings()
    public static let controlStyleKey = "extera.style.controlStyle"
    public static let sectionRadiusKey = "extera.style.sectionRadius"
    public static let separateHeadersKey = "extera.style.separateHeaders"
    public static let separatorStyleKey = "extera.style.separatorStyle"
    public static let glassBorderKey = "extera.style.glassBorder"
    public static let glassMessageMenuKey = "extera.style.glassMessageMenu"
    public static let forceBlurKey = "extera.style.forceBlur"
    public static let minimumSectionRadius = 0
    public static let maximumSectionRadius = 64
    public static let defaultSectionRadius = 22
    public static var booleanKeys: [String] { return [Self.separateHeadersKey, Self.glassMessageMenuKey, Self.forceBlurKey] }
    public static var integerKeys: [String] { return [Self.controlStyleKey, Self.sectionRadiusKey] }
    public static var stringKeys: [String] { return [Self.separatorStyleKey, Self.glassBorderKey] }

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            Self.controlStyleKey: ControlStyle.material.rawValue,
            Self.sectionRadiusKey: Self.defaultSectionRadius,
            Self.separateHeadersKey: true,
            Self.separatorStyleKey: SeparatorStyle.line.rawValue,
            Self.glassBorderKey: GlassBorder.none.rawValue,
            Self.glassMessageMenuKey: false,
            Self.forceBlurKey: false
        ])
    }

    public static func normalizedSectionRadius(_ value: Int) -> Int {
        return max(Self.minimumSectionRadius, min(Self.maximumSectionRadius, value))
    }

    public var controlStyle: ControlStyle {
        get { return ControlStyle(rawValue: self.store.int(Self.controlStyleKey)) ?? .material }
        set { self.store.setInt(newValue.rawValue, Self.controlStyleKey) }
    }

    public var sectionRadius: Int {
        get { return Self.normalizedSectionRadius(self.store.int(Self.sectionRadiusKey)) }
        set { self.store.setInt(Self.normalizedSectionRadius(newValue), Self.sectionRadiusKey) }
    }

    public var separateHeaders: Bool {
        get { return self.store.bool(Self.separateHeadersKey) }
        set { self.store.setBool(newValue, Self.separateHeadersKey) }
    }

    public var separatorStyle: SeparatorStyle {
        get { return SeparatorStyle(rawValue: self.store.string(Self.separatorStyleKey)) ?? .line }
        set { self.store.setString(newValue.rawValue, Self.separatorStyleKey) }
    }

    public var glassBorder: GlassBorder {
        get { return GlassBorder(rawValue: self.store.string(Self.glassBorderKey)) ?? .none }
        set { self.store.setString(newValue.rawValue, Self.glassBorderKey) }
    }

    public var glassMessageMenu: Bool {
        get { return self.store.bool(Self.glassMessageMenuKey) }
        set { self.store.setBool(newValue, Self.glassMessageMenuKey) }
    }

    public var forceBlur: Bool {
        get { return self.store.bool(Self.forceBlurKey) }
        set { self.store.setBool(newValue, Self.forceBlurKey) }
    }
}
