import Foundation

/// Native mutations used by the composed page. Other font/theme modes remain intact.
public enum ExteraNativeChatControls {
    public static let fontSizes: [PresentationFontSize] = [.extraSmall, .small, .medium, .regular, .large, .extraLarge, .extraLargeX2]
    public static let bubbleRadiusRange = 0 ... 17

    public static func withFontSize(_ size: PresentationFontSize, settings: PresentationThemeSettings) -> PresentationThemeSettings {
        var settings = settings
        settings.fontSize = size
        return settings
    }

    public static func withBubbleRadius(_ radius: Int, settings: PresentationThemeSettings) -> PresentationThemeSettings {
        var settings = settings
        let radius = max(self.bubbleRadiusRange.lowerBound, min(self.bubbleRadiusRange.upperBound, radius))
        settings.chatBubbleSettings.mainRadius = Int32(radius)
        settings.chatBubbleSettings.auxiliaryRadius = Int32(radius / 2)
        return settings
    }
}
