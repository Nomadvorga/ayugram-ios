import AccountContext
import Display
import Emoji
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ThemeCarouselItem

/// The native theme carousel row used by the composed chat-settings page.
/// Theme cards remain backed by PresentationThemeSettings; this type owns no parallel selection state.
public struct ExteraInlineChatThemes: Equatable {
    private let themes: [PresentationThemeReference]
    private let animatedEmojiStickers: [String: [StickerPackItem]]

    fileprivate init(themes: [PresentationThemeReference], animatedEmojiStickers: [String: [StickerPackItem]]) {
        self.themes = themes
        self.animatedEmojiStickers = animatedEmojiStickers
    }

    public static func == (lhs: ExteraInlineChatThemes, rhs: ExteraInlineChatThemes) -> Bool {
        return lhs.themes == rhs.themes && Set(lhs.animatedEmojiStickers.keys) == Set(rhs.animatedEmojiStickers.keys)
    }

    public func item(
        context: AccountContext,
        presentationData: ItemListPresentationData,
        settings: PresentationThemeSettings,
        autoNightModeTriggered: Bool,
        sectionId: ItemListSectionId,
        selected: @escaping (PresentationThemeReference) -> Void
    ) -> ListViewItem {
        let bubbleMode = settings.chatBubbleSettings.bubbleMode
        let carouselThemes: [PresentationThemeReference]
        if bubbleMode {
            carouselThemes = [.builtin(.dayClassic)] + self.themes
        } else {
            carouselThemes = bubblelessCarouselThemes(chatThemes: self.themes)
        }
        let currentTheme: PresentationThemeReference
        if bubbleMode {
            let selectedTheme = settings.currentModeTheme
            if autoNightModeTriggered, selectedTheme.emoticon == nil {
                currentTheme = settings.currentModeAutomaticThemeSwitchSetting.theme
            } else {
                currentTheme = selectedTheme
            }
        } else {
            currentTheme = bubblelessCarouselSelection(settings: settings, autoNightModeTriggered: autoNightModeTriggered)
        }
        return ThemeCarouselThemeItem(
            context: context,
            theme: presentationData.theme,
            strings: presentationData.strings,
            sectionId: sectionId,
            themes: carouselThemes,
            hasNoTheme: false,
            animatedEmojiStickers: self.animatedEmojiStickers,
            themeSpecificAccentColors: settings.themeSpecificAccentColors,
            themeSpecificChatWallpapers: settings.themeSpecificChatWallpapers,
            nightMode: settings.currentModeAutomaticThemeSwitchSetting.force || autoNightModeTriggered,
            bubbleless: !bubbleMode,
            currentTheme: currentTheme,
            updatedTheme: { reference in
                if let reference {
                    selected(reference)
                }
            },
            contextAction: nil
        )
    }
}

/// Loads the same chat-theme and animated-emoji inventories as the native Themes page.
public func exteraInlineChatThemes(context: AccountContext) -> Signal<ExteraInlineChatThemes, NoError> {
    let themes = context.engine.themes.themes(accountManager: context.sharedContext.accountManager)
    let animatedEmoji = context.engine.stickers.loadedStickerPack(reference: .animatedEmoji, forceActualized: false)
    return combineLatest(themes, animatedEmoji)
    |> map { themes, animatedEmoji -> ExteraInlineChatThemes in
        var stickers: [String: [StickerPackItem]] = [:]
        if case let .result(_, items, _) = animatedEmoji {
            for item in items {
                if let emoji = item.getStringRepresentationsOfIndexKeys().first {
                    stickers[emoji.basicEmoji.0] = [item]
                    let strippedEmoji = emoji.basicEmoji.0.strippedEmoji
                    if stickers[strippedEmoji] == nil {
                        stickers[strippedEmoji] = [item]
                    }
                }
            }
        }
        let references = themes
            .filter { $0.emoticon != nil }
            .map { theme in
                PresentationThemeReference.cloud(PresentationCloudTheme(theme: theme, resolvedWallpaper: nil, creatorAccountId: theme.isCreator ? context.account.id : nil))
            }
        return ExteraInlineChatThemes(themes: references, animatedEmojiStickers: stickers)
    }
}
