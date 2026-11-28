import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import AccountContext
import ContextUI
import UndoUI
import SGStrings
import SGSimpleSettings
import ChatControllerInteraction
import ChatPresentationInterfaceState

// "Details" (exteraGram): a submenu of the message menu with what is known about the message and its file.
// A tap on a row copies its value.
private struct AyuMessageDetail {
    let title: String
    let value: String
    let iconName: String
}

private func ayuDatacenterName(_ id: Int) -> String {
    switch id {
    case 1, 3:
        return "DC\(id), Miami FL, USA"
    case 2, 4:
        return "DC\(id), Amsterdam, NL"
    case 5:
        return "DC\(id), Singapore, SG"
    default:
        return "DC\(id)"
    }
}

private func ayuMessageDetails(chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> [[AyuMessageDetail]] {
    let strings = chatPresentationInterfaceState.strings
    let lang = strings.baseLanguageCode
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    let dateString: (Int32) -> String = { date in
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(date)))
    }

    var counters: [AyuMessageDetail] = []
    var general: [AyuMessageDetail] = []
    var media: [AyuMessageDetail] = []

    for attribute in message.attributes {
        if let attribute = attribute as? ViewCountMessageAttribute, attribute.count > 0 {
            counters.append(AyuMessageDetail(title: i18n("Extera.DetailsViews", lang), value: "\(attribute.count)", iconName: "Chat/Context Menu/Eye"))
        } else if let attribute = attribute as? ForwardCountMessageAttribute, attribute.count > 0 {
            counters.append(AyuMessageDetail(title: i18n("Extera.DetailsForwards", lang), value: "\(attribute.count)", iconName: "Chat/Context Menu/Forward"))
        }
    }

    if message.id.namespace == Namespaces.Message.Cloud {
        general.append(AyuMessageDetail(title: "ID", value: "\(message.id.id)", iconName: "Chat/Context Menu/Info"))
    }
    if message.timestamp > 0 {
        general.append(AyuMessageDetail(title: i18n("Extera.DetailsDate", lang), value: dateString(message.timestamp), iconName: "Chat/Context Menu/Calendar"))
    }
    if let forwardInfo = message.forwardInfo, forwardInfo.date > 0, forwardInfo.date != message.timestamp {
        general.append(AyuMessageDetail(title: i18n("Extera.DetailsForwardDate", lang), value: dateString(forwardInfo.date), iconName: "Chat/Context Menu/Forward"))
    }
    for attribute in message.attributes {
        if let attribute = attribute as? EditedMessageAttribute, !attribute.isHidden, attribute.date > 0, attribute.date != message.timestamp {
            general.append(AyuMessageDetail(title: i18n("Extera.DetailsEditDate", lang), value: dateString(attribute.date), iconName: "Chat/Context Menu/Edit"))
        }
    }

    var file: TelegramMediaFile?
    var image: TelegramMediaImage?
    for item in message.media {
        if let item = item as? TelegramMediaFile {
            file = item
        } else if let item = item as? TelegramMediaImage {
            image = item
        } else if let item = item as? TelegramMediaWebpage, case let .Loaded(content) = item.content {
            file = file ?? content.file
            image = image ?? content.image
        }
    }

    var datacenterId: Int?
    if let file {
        if let size = file.size, size > 0 {
            let formatting = DataSizeStringFormatting(decimalSeparator: chatPresentationInterfaceState.dateTimeFormat.decimalSeparator, byte: strings.FileSize_B(_:), kilobyte: strings.FileSize_KB(_:), megabyte: strings.FileSize_MB(_:), gigabyte: strings.FileSize_GB(_:))
            media.append(AyuMessageDetail(title: i18n("Extera.DetailsFileSize", lang), value: dataSizeString(size, formatting: formatting), iconName: "Chat/Context Menu/Download"))
        }
        if !file.mimeType.isEmpty {
            media.append(AyuMessageDetail(title: i18n("Extera.DetailsMimeType", lang), value: file.mimeType, iconName: "Chat/Context Menu/Info"))
        }
        if let fileName = file.fileName, !fileName.isEmpty {
            media.append(AyuMessageDetail(title: i18n("Extera.DetailsFileName", lang), value: fileName, iconName: "Chat/Context Menu/Copy"))
        }
        if let dimensions = file.dimensions {
            media.append(AyuMessageDetail(title: i18n("Extera.DetailsResolution", lang), value: "\(dimensions.width)x\(dimensions.height)", iconName: "Chat/Context Menu/Image"))
        }
        if let duration = file.duration, duration >= 1.0 {
            media.append(AyuMessageDetail(title: i18n("Extera.DetailsDuration", lang), value: stringForDuration(Int32(duration)), iconName: "Chat/Context Menu/Timer"))
        }
        datacenterId = (file.resource as? CloudDocumentMediaResource)?.datacenterId
    } else if let image, let representation = largestImageRepresentation(image.representations) {
        media.append(AyuMessageDetail(title: i18n("Extera.DetailsResolution", lang), value: "\(representation.dimensions.width)x\(representation.dimensions.height)", iconName: "Chat/Context Menu/Image"))
        datacenterId = (representation.resource as? CloudPhotoSizeMediaResource)?.datacenterId
    }
    if let datacenterId, datacenterId > 0 {
        media.append(AyuMessageDetail(title: i18n("Extera.DetailsDatacenter", lang), value: ayuDatacenterName(datacenterId), iconName: "Chat/Context Menu/Globe"))
    }

    return [counters, general, media].filter { !$0.isEmpty }
}

func ayuMakeMessageDetailsContextMenuAction(controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    if !ExteraSettings.shared.showDetailsButton {
        return nil
    }
    if message.adAttribute != nil || message.media.contains(where: { $0 is TelegramMediaAction }) {
        return nil
    }
    let groups = ayuMessageDetails(chatPresentationInterfaceState: chatPresentationInterfaceState, message: message)
    if groups.isEmpty {
        return nil
    }
    let strings = chatPresentationInterfaceState.strings
    return .action(ContextMenuActionItem(text: i18n("Extera.Details", strings.baseLanguageCode), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Info"), color: theme.actionSheet.primaryTextColor)
    }, action: { c, _ in
        var subItems: [ContextMenuItem] = []
        subItems.append(.action(ContextMenuActionItem(text: strings.Common_Back, textColor: .primary, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.actionSheet.primaryTextColor)
        }, iconSource: nil, iconPosition: .left, action: { c, _ in
            c?.popItems()
        })))
        for group in groups {
            subItems.append(.separator)
            for detail in group {
                subItems.append(.action(ContextMenuActionItem(text: detail.title, textLayout: .secondLineWithValue(detail.value), icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: detail.iconName), color: theme.actionSheet.primaryTextColor)
                }, action: { _, f in
                    UIPasteboard.general.string = detail.value
                    f(.default)
                    controllerInteraction.displayUndo(.copy(text: strings.Conversation_TextCopied))
                })))
            }
        }
        c?.pushItems(items: .single(ContextController.Items(content: .list(subItems))))
    }))
}
