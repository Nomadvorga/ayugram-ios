import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import UndoUI
import OverlayStatusController
import PresentationDataUtils
import SGStrings
import SGSimpleSettings
import ChatControllerInteraction
import ChatPresentationInterfaceState

// MARK: AyuGram
// "Search Image" (exteraGram): looks a downloaded photo of a message up with Yandex, Google Lens, Bing or TinEye.

private let ayuReverseImageSearchSession = URLSession(configuration: .ephemeral)
private let ayuReverseImageSearchUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

// A JPEG of at most 1280 points on its longer side.
private func ayuReverseImageSearchJpeg(path: String) -> Data? {
    guard let image = UIImage(contentsOfFile: path), image.size.width > 0.0, image.size.height > 0.0 else {
        return nil
    }
    let side = max(image.size.width, image.size.height) * image.scale
    let factor = min(1.0, CGFloat(AyuReverseImageSearch.maxImageSide) / side)
    let size = CGSize(width: max(1.0, floor(image.size.width * image.scale * factor)), height: max(1.0, floor(image.size.height * image.scale * factor)))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    return scaled.jpegData(compressionQuality: 0.85)
}

func ayuMakeSearchImageContextMenuAction(context: AccountContext, controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    guard ExteraSettings.shared.value(.showSearchImageButton) else {
        return nil
    }
    // A picture that may not leave the chat is not sent to a search service either.
    if chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected() || message.containsSecretMedia || message.id.peerId.namespace == Namespaces.Peer.SecretChat {
        return nil
    }
    guard let image = message.media.first(where: { $0 is TelegramMediaImage }) as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations), let path = context.account.postbox.mediaBox.completedResourcePath(representation.resource) else {
        return nil
    }
    let strings = chatPresentationInterfaceState.strings
    let lang = strings.baseLanguageCode
    return .action(ContextMenuActionItem(text: i18n("Extera.SearchImage", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Search"), color: theme.actionSheet.primaryTextColor)
    }, action: { [weak controllerInteraction] controller, f in
        controller?.dismiss(completion: {
            guard let controllerInteraction else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            var items: [ActionSheetItem] = [ActionSheetTextItem(title: i18n("Extera.SearchImageInfo", lang))]
            for provider in AyuReverseImageSearch.Provider.allCases {
                items.append(ActionSheetButtonItem(title: provider.title, color: .accent, action: { [weak actionSheet, weak controllerInteraction] in
                    actionSheet?.dismissAnimated()
                    guard let controllerInteraction else {
                        return
                    }
                    ayuSearchImage(context: context, controllerInteraction: controllerInteraction, path: path, provider: provider)
                }))
            }
            actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            controllerInteraction.presentController(actionSheet, nil)
        })
    }))
}

private func ayuSearchImage(context: AccountContext, controllerInteraction: ChatControllerInteraction, path: String, provider: AyuReverseImageSearch.Provider) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var task: URLSessionDataTask?
    var isCancelled = false
    let statusController = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
        isCancelled = true
        task?.cancel()
    }))
    controllerInteraction.presentController(statusController, nil)

    let finish: (String?) -> Void = { [weak statusController, weak controllerInteraction] url in
        statusController?.dismiss()
        guard !isCancelled, let controllerInteraction else {
            return
        }
        if let url {
            controllerInteraction.openUrl(ChatControllerInteraction.OpenUrl(url: url, concealed: false, external: false))
        } else {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            controllerInteraction.presentControllerInCurrent(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: i18n("Extera.SearchImageFailed", presentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), nil)
        }
    }

    DispatchQueue.global(qos: .userInitiated).async {
        guard let jpeg = ayuReverseImageSearchJpeg(path: path) else {
            DispatchQueue.main.async {
                finish(nil)
            }
            return
        }
        let request = AyuReverseImageSearch.uploadRequest(jpeg: jpeg, userAgent: ayuReverseImageSearchUserAgent)
        DispatchQueue.main.async {
            if isCancelled {
                return
            }
            let uploadTask = ayuReverseImageSearchSession.dataTask(with: request, completionHandler: { data, response, _ in
                var url: String?
                if let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode), let data {
                    url = AyuReverseImageSearch.searchURL(provider: provider, uploadResponse: data, uploadHost: response.url?.host ?? "yandex.com")
                }
                DispatchQueue.main.async {
                    finish(url)
                }
            })
            task = uploadTask
            uploadTask.resume()
        }
    }
}
