import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI
import Display
import SGStrings
import SGSimpleSettings

// MARK: AyuGram
// What exteraGram's badge next to a name stands for: the owner's own text, else the kind of profile.
func ayuExteraBadgeInfoText(profile: AyuExteraProfile, name: String, lang: String) -> String {
    // The name goes into markdown: its own markup must not open or close anything.
    let name = name.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    if let text = profile.badgeText {
        return text.replacingOccurrences(of: "{name}", with: name)
    }
    let key: String
    if profile.status == .developer {
        key = profile.isUser ? "Extera.Badge.Developer" : "Extera.Badge.OfficialChannel"
    } else {
        key = "Extera.Badge.Supporter"
    }
    return i18n(key, lang, name)
}

func ayuPresentExteraBadgeInfo(context: AccountContext, presentationData: PresentationData, peer: EnginePeer, present: @escaping (ViewController) -> Void) -> Bool {
    let isUser: Bool
    if case .user = peer {
        isUser = true
    } else {
        isUser = false
    }
    guard let profile = AyuExteraProfilesStore.shared.profile(id: peer.id.id._internalGetInt64Value(), isUser: isUser), let fileId = profile.badgeDocumentId else {
        return false
    }
    let name = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
    let text = ayuExteraBadgeInfoText(profile: profile, name: name, lang: presentationData.strings.baseLanguageCode)
    let _ = (context.engine.stickers.resolveInlineStickers(fileIds: [fileId])
    |> deliverOnMainQueue).startStandalone(next: { files in
        guard let file = files[fileId] else {
            return
        }
        present(UndoOverlayController(presentationData: presentationData, content: .sticker(context: context, file: file, loop: true, title: profile.formattedNumber, text: text, undoText: nil, customAction: nil), elevatedLayout: false, action: { _ in
            return false
        }))
    })
    return true
}
