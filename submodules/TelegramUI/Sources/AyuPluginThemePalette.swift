import AyuPluginBridge
import TelegramPresentationData
import UIKit

extension AyuPluginThemePalette {
    /// Each slot from the element of the presentation theme its name describes.
    init(presentationData: PresentationData) {
        let theme = presentationData.theme
        let list = theme.list, sheet = theme.actionSheet, bar = theme.rootController.navigationBar
        let chats = theme.chatList, panel = theme.chat.inputPanel
        let incoming = theme.chat.message.incoming, outgoing = theme.chat.message.outgoing
        var colors: [Slot: UIColor] = [
            .dialogBackground: sheet.opaqueItemBackgroundColor,
            .dialogGroupedBackground: list.modalBlocksBackgroundColor,
            .dialogPrimaryText: sheet.primaryTextColor,
            .dialogSecondaryText: sheet.secondaryTextColor,
            .dialogPlaceholderText: sheet.inputPlaceholderColor,
            .dialogAccent: sheet.controlAccentColor,
            .dialogActionText: sheet.standardActionTextColor,
            .dialogSeparator: sheet.opaqueItemSeparatorColor,
            .dialogInputBackground: sheet.inputBackgroundColor,
            .dialogInputBorder: sheet.inputBorderColor,
            .listBackground: list.blocksBackgroundColor,
            .listItemBackground: list.itemBlocksBackgroundColor,
            .listPrimaryText: list.itemPrimaryTextColor,
            .listSecondaryText: list.itemSecondaryTextColor,
            .listFreeText: list.freeTextColor,
            .listPlaceholderText: list.itemPlaceholderTextColor,
            .listDisabledText: list.itemDisabledTextColor,
            .listAccent: list.itemAccentColor,
            .listDestructive: list.itemDestructiveColor,
            .listSeparator: list.itemBlocksSeparatorColor,
            .listHighlight: list.itemHighlightedBackgroundColor,
            .listSectionHeaderFill: chats.sectionHeaderFillColor,
            .listInputStroke: list.itemInputField.strokeColor,
            .listControlSecondary: list.controlSecondaryColor,
            .listMediaPlaceholder: list.mediaPlaceholderColor,
            .checkFill: list.itemCheckColors.fillColor,
            .checkStroke: list.itemCheckColors.strokeColor,
            .checkForeground: list.itemCheckColors.foregroundColor,
            .switchOff: list.itemSwitchColors.frameColor,
            .switchOn: list.itemSwitchColors.positiveColor,
            .navigationBackground: bar.opaqueBackgroundColor,
            .navigationPrimaryText: bar.primaryTextColor,
            .navigationSecondaryText: bar.secondaryTextColor,
            .navigationButton: bar.buttonColor,
            .navigationControl: bar.controlColor,
            .navigationAccent: bar.accentTextColor,
            .menuBackground: theme.contextMenu.backgroundColor,
            .menuPrimary: theme.contextMenu.primaryColor,
            .chatListTitle: chats.titleColor,
            .chatListSecretTitle: chats.secretTitleColor,
            .chatListMessageText: chats.messageTextColor,
            .chatListDate: chats.dateTextColor,
            .chatListUnreadBadge: chats.unreadBadgeActiveBackgroundColor,
            .chatListPinnedBackground: chats.pinnedItemBackgroundColor,
            .incomingText: incoming.primaryTextColor,
            .outgoingText: outgoing.primaryTextColor,
            .incomingLink: incoming.linkTextColor,
            .outgoingLink: outgoing.linkTextColor,
            .incomingMediaControl: incoming.mediaActiveControlColor,
            .incomingReactionBackground: incoming.bubble.withWallpaper.reactionActiveBackground,
            .inputPanelBackground: panel.panelBackgroundColorNoWallpaper,
            .inputPanelSeparator: panel.panelSeparatorColor,
            .inputPanelText: panel.primaryTextColor,
            .inputPanelPlaceholder: panel.inputPlaceholderColor,
            .inputPanelControl: panel.panelControlColor,
            .inputPanelAction: panel.actionControlFillColor,
            .mediaPanelBackground: theme.chat.inputMediaPanel.backgroundColor,
        ]
        // A gradient bubble is represented by its first colour, as Android's bubble key is.
        colors[.incomingBubble] = incoming.bubble.withWallpaper.fill.first
        colors[.outgoingBubble] = outgoing.bubble.withWallpaper.fill.first
        self.init(isDark: theme.overallDarkAppearance, isNight: presentationData.autoNightModeTriggered,
                  colors: colors.compactMapValues(Self.argb))
    }

    private static func argb(_ color: UIColor) -> UInt32? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return byte(alpha) << 24 | byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}

extension AyuPluginLanguage {
    init(strings: PresentationStrings) {
        self.init(code: strings.primaryComponent.languageCode, baseCode: strings.secondaryComponent?.languageCode)
    }
}
