import Foundation

/// General preferences without a counterpart in the existing ExteraSettings store.
public final class ExteraGeneralSettings: @unchecked Sendable {
    public static let shared = ExteraGeneralSettings()

    public enum DefaultProfileTab: Int, CaseIterable {
        case `default` = 0
        case media = 1
        case groupsInCommon = 2
    }

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            "extera.general.defaultProfileTab": DefaultProfileTab.default.rawValue,
        ])
    }

    /// Selects an available profile pane without overriding explicit navigation to media or gifts.
    public var defaultProfileTab: DefaultProfileTab {
        get { return DefaultProfileTab(rawValue: self.store.int("extera.general.defaultProfileTab")) ?? .default }
        set { self.store.setInt(newValue.rawValue, "extera.general.defaultProfileTab") }
    }
}
