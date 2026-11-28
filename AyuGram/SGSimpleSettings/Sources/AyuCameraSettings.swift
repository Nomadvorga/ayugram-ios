import Foundation

// Round videos start on the camera they were last recorded with.
public final class AyuCameraSettings: @unchecked Sendable {
    public static let shared = AyuCameraSettings()

    private static let roundVideoBackCameraKey = "ayu.camera.roundVideoBack"

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [AyuCameraSettings.roundVideoBackCameraKey: false])
    }

    public var roundVideoUsesBackCamera: Bool {
        get { return self.store.bool(AyuCameraSettings.roundVideoBackCameraKey) }
        set { self.store.setBool(newValue, AyuCameraSettings.roundVideoBackCameraKey) }
    }
}
