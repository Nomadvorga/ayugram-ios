import Foundation

/// Visibility and grouping of the non-plugin exteraGram message menu actions.
public final class ExteraMenuSettings: @unchecked Sendable {
    public static let shared = ExteraMenuSettings()

    public enum Keys: String, CaseIterable {
        case showCopyPhotoButton
        case showSaveMessageButton
        case showRepeatMessageButton
        case showClearButton
        case showHistoryButton
        case showReportButton
        case showGenerateButton
        case showDetailsButton
        case showMessageImageExportButton
        case groupMessageMenu
    }

    private let store = AyuSettingsStore.shared

    private init() {
        // Match exteraGram for Android's defaults. These keys do not change the
        // separate Swiftgram preferences for actions in the AyuGram submenu.
        self.store.register(defaults: [
            Self.key(.showCopyPhotoButton): true,
            Self.key(.showSaveMessageButton): false,
            Self.key(.showRepeatMessageButton): false,
            Self.key(.showClearButton): true,
            Self.key(.showHistoryButton): false,
            Self.key(.showReportButton): true,
            Self.key(.showGenerateButton): true,
            Self.key(.showDetailsButton): false,
            Self.key(.showMessageImageExportButton): false,
            Self.key(.groupMessageMenu): true,
        ])
    }

    private static func key(_ key: Keys) -> String {
        return "extera.menu." + key.rawValue
    }

    public var showCopyPhotoButton: Bool {
        get { return self.store.bool(Self.key(.showCopyPhotoButton)) }
        set { self.store.setBool(newValue, Self.key(.showCopyPhotoButton)) }
    }

    public var showSaveMessageButton: Bool {
        get { return self.store.bool(Self.key(.showSaveMessageButton)) }
        set { self.store.setBool(newValue, Self.key(.showSaveMessageButton)) }
    }

    public var showRepeatMessageButton: Bool {
        get { return self.store.bool(Self.key(.showRepeatMessageButton)) }
        set { self.store.setBool(newValue, Self.key(.showRepeatMessageButton)) }
    }

    public var showClearButton: Bool {
        get { return self.store.bool(Self.key(.showClearButton)) }
        set { self.store.setBool(newValue, Self.key(.showClearButton)) }
    }

    /// Search the current group or topic for messages from the selected author.
    public var showHistoryButton: Bool {
        get { return self.store.bool(Self.key(.showHistoryButton)) }
        set { self.store.setBool(newValue, Self.key(.showHistoryButton)) }
    }

    public var showReportButton: Bool {
        get { return self.store.bool(Self.key(.showReportButton)) }
        set { self.store.setBool(newValue, Self.key(.showReportButton)) }
    }

    /// The item appears only while an AI service is set up, so the default changes nothing for a stock setup.
    public var showGenerateButton: Bool {
        get { return self.store.bool(Self.key(.showGenerateButton)) }
        set { self.store.setBool(newValue, Self.key(.showGenerateButton)) }
    }

    public var showDetailsButton: Bool {
        get { return self.store.bool(Self.key(.showDetailsButton)) }
        set { self.store.setBool(newValue, Self.key(.showDetailsButton)) }
    }

    public var groupMessageMenu: Bool {
        get { return self.store.bool(Self.key(.groupMessageMenu)) }
        set { self.store.setBool(newValue, Self.key(.groupMessageMenu)) }
    }

    /// Export the visible message as an image, subject to normal copy permissions.
    public var showMessageImageExportButton: Bool {
        get { return self.store.bool(Self.key(.showMessageImageExportButton)) }
        set { self.store.setBool(newValue, Self.key(.showMessageImageExportButton)) }
    }
}
