import AccountContext
import Foundation
import MediaResources
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import WallpaperResources

/// Applies a theme through the existing account-manager/native appearance pipeline.
/// Completion reports whether the native crossfade-accent transition is required.
public func exteraSelectChatTheme(context: AccountContext, theme: PresentationThemeReference, completion: @escaping (Bool) -> Void = { _ in }) {
    guard let presentationTheme = makePresentationTheme(mediaBox: context.sharedContext.accountManager.mediaBox, themeReference: theme) else {
        return
    }

    let autoNightModeTriggered = context.sharedContext.currentPresentationData.with { $0 }.autoNightModeTriggered

    let resolvedWallpaper: Signal<TelegramWallpaper?, NoError>
    if case let .file(file) = presentationTheme.chat.defaultWallpaper, file.id == 0 {
        resolvedWallpaper = cachedWallpaper(engine: context.engine, network: context.account.network, slug: file.slug, settings: file.settings)
        |> map { wallpaper -> TelegramWallpaper? in
            return wallpaper?.wallpaper
        }
    } else {
        resolvedWallpaper = .single(nil)
    }

    var cloudTheme: TelegramTheme?
    if case let .cloud(theme) = theme {
        cloudTheme = theme.theme
    }
    let _ = applyTheme(accountManager: context.sharedContext.accountManager, account: context.account, theme: cloudTheme).start()

    let currentTheme = context.sharedContext.accountManager.transaction { transaction -> (PresentationThemeReference) in
        let settings = transaction.getSharedData(ApplicationSpecificSharedDataKeys.presentationThemeSettings)?.get(PresentationThemeSettings.self) ?? PresentationThemeSettings.defaultSettings
        if autoNightModeTriggered {
            return settings.currentModeAutomaticThemeSwitchSetting.theme
        } else {
            return settings.currentModeTheme
        }
    }

    let _ = (combineLatest(resolvedWallpaper, currentTheme)
    |> map { resolvedWallpaper, currentTheme -> Bool in
        var updatedTheme = theme
        var currentThemeBaseIndex: Int64?
        if case let .cloud(info) = currentTheme, let settings = info.theme.settings?.first {
            currentThemeBaseIndex = PresentationThemeReference.builtin(PresentationBuiltinThemeReference(baseTheme: settings.baseTheme)).index
        } else {
            currentThemeBaseIndex = currentTheme.index
        }

        var baseThemeIndex: Int64?
        var updatedThemeBaseIndex: Int64?
        if case let .cloud(info) = theme {
            updatedTheme = .cloud(PresentationCloudTheme(theme: info.theme, resolvedWallpaper: resolvedWallpaper, creatorAccountId: info.theme.isCreator ? context.account.id : nil))
            if let settings = info.theme.settings?.first {
                baseThemeIndex = PresentationThemeReference.builtin(PresentationBuiltinThemeReference(baseTheme: settings.baseTheme)).index
                updatedThemeBaseIndex = baseThemeIndex
            }
        } else {
            updatedThemeBaseIndex = theme.index
        }

        let _ = updatePresentationThemeSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
            // MARK: AyuGram
            // Tapping the theme that is already selected changes nothing.
            if current.currentModeTheme.index == updatedTheme.index && (!autoNightModeTriggered || current.currentModeAutomaticThemeSwitchSetting.theme.index == updatedTheme.index) {
                return current
            }
            //
            if !current.chatBubbleSettings.bubbleMode {
                var updated = current
                updated.currentModeTheme = updatedTheme
                updated.currentModeAutomaticThemeSwitchSetting.theme = bubblelessAutomaticTheme(afterSelecting: updatedTheme, current: updated.currentModeAutomaticThemeSwitchSetting.theme)
                return updated
            }
            var updatedAutomaticThemeSwitchSetting = current.automaticThemeSwitchSetting
            if case let .cloud(info) = updatedTheme, info.theme.settings?.contains(where: { $0.baseTheme == .night || $0.baseTheme == .tinted }) ?? false {
                // MARK: AyuGram
                // A chat theme keeps the night theme chosen under Auto-Night: Night or Tinted Night is the base it is
                // drawn on at night, and a custom night theme stays unless the pick is made at night.
                let keptNightTheme: Bool
                switch updatedAutomaticThemeSwitchSetting.theme {
                case .builtin(.night), .builtin(.nightAccent):
                    keptNightTheme = info.theme.emoticon != nil
                case .cloud, .local:
                    keptNightTheme = info.theme.emoticon != nil && updatedAutomaticThemeSwitchSetting.theme.emoticon == nil && !autoNightModeTriggered
                default:
                    keptNightTheme = false
                }
                if !keptNightTheme {
                    updatedAutomaticThemeSwitchSetting.theme = updatedTheme
                }
            } else if case let .builtin(theme) = updatedTheme {
                if [.day, .dayClassic].contains(theme) {
                    if updatedAutomaticThemeSwitchSetting.theme.emoticon != nil || [.builtin(.dayClassic), .builtin(.day)].contains(updatedAutomaticThemeSwitchSetting.theme.generalThemeReference) {
                        updatedAutomaticThemeSwitchSetting.theme = .builtin(.night)
                    }
                } else {
                    updatedAutomaticThemeSwitchSetting.theme = updatedTheme
                }
            }
            return current.withUpdatedTheme(updatedTheme).withUpdatedAutomaticThemeSwitchSetting(updatedAutomaticThemeSwitchSetting)

        }).start()

        return currentThemeBaseIndex != updatedThemeBaseIndex
    } |> deliverOnMainQueue).start(next: { crossfadeAccentColors in
        completion((cloudTheme == nil || cloudTheme?.settings != nil) && !crossfadeAccentColors)
    })
}
