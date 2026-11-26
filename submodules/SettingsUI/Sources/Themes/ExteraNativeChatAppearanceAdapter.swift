import AccountContext
import Display
import ItemListUI
import LocalizedPeerData
import PeerNameColorScreen
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import WallpaperGridScreen

/// Exposes the existing message renderer to the composed chat settings page.
/// The preview uses the same wallpaper, fonts and corner settings as a real chat.
public struct ExteraNativeChatPreview: Equatable {
    private let data: PresentationData
    private let peer: EnginePeer?

    public init(presentationData: PresentationData, accountPeer: EnginePeer?) {
        self.data = presentationData
        self.peer = accountPeer
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.data.theme === rhs.data.theme
            && lhs.data.strings === rhs.data.strings
            && lhs.data.chatWallpaper == rhs.data.chatWallpaper
            && lhs.data.chatFontSize == rhs.data.chatFontSize
            && lhs.data.chatBubbleCorners == rhs.data.chatBubbleCorners
            && lhs.data.dateTimeFormat == rhs.data.dateTimeFormat
            && lhs.data.nameDisplayOrder == rhs.data.nameDisplayOrder
            && lhs.peer == rhs.peer
    }

    public func item(context: AccountContext, sectionId: ItemListSectionId) -> ListViewItem {
        let author: String
        if let peer = self.peer, peer.hasCustomNameColor {
            author = peer.displayTitle(strings: self.data.strings, displayOrder: self.data.nameDisplayOrder)
        } else {
            author = self.data.strings.Appearance_PreviewReplyAuthor
        }
        return ThemeSettingsChatPreviewItem(
            context: context, theme: self.data.theme, componentTheme: self.data.theme,
            strings: self.data.strings, sectionId: sectionId, fontSize: self.data.chatFontSize,
            chatBubbleCorners: self.data.chatBubbleCorners, wallpaper: self.data.chatWallpaper,
            dateTimeFormat: self.data.dateTimeFormat, nameDisplayOrder: self.data.nameDisplayOrder,
            messageItems: [
                ChatPreviewMessageItem(outgoing: false, reply: (author, self.data.strings.Appearance_PreviewReplyText), text: self.data.strings.Appearance_PreviewIncomingText, nameColor: self.peer?.nameColor ?? .preset(.blue), backgroundEmojiId: self.peer?.backgroundEmojiId),
                ChatPreviewMessageItem(outgoing: true, reply: nil, text: self.data.strings.Appearance_PreviewOutgoingText, nameColor: .preset(.blue), backgroundEmojiId: nil)
            ]
        )
    }
}

public func exteraChatWallpaperController(context: AccountContext) -> ViewController {
    return ThemeGridController(context: context)
}

public func exteraChatNameColorController(context: AccountContext) -> ViewController {
    return UserAppearanceScreen(context: context)
}

public func exteraChatTextSizeController(context: AccountContext, settings: PresentationThemeSettings) -> ViewController {
    return TextSizeSelectionController(context: context, presentationThemeSettings: settings)
}
