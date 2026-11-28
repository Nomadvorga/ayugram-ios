import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import PresentationDataUtils
import Display
import UndoUI
import SGStrings

// MARK: AyuGram
// exteraGram's menu of an IP address in a message: where the address is and whose it is.

private let ayuIpAddressInfoSession = URLSession(configuration: .ephemeral)
private var ayuIpAddressInfoCache: [String: (info: AyuIpAddressInfo?, time: Double)] = [:]

// Answers on the main queue. Answers are remembered for a day, refusals for five minutes.
private func ayuRequestIpAddressInfo(_ ipAddress: String, completion: @escaping (AyuIpAddressInfo?) -> Void) {
    let now = CFAbsoluteTimeGetCurrent()
    if let cached = ayuIpAddressInfoCache[ipAddress], now - cached.time <= (cached.info != nil ? 24.0 * 60.0 * 60.0 : 5.0 * 60.0), now >= cached.time {
        completion(cached.info)
        return
    }
    guard let request = AyuIpAddressInfo.request(ipAddress: ipAddress) else {
        completion(nil)
        return
    }
    ayuIpAddressInfoSession.dataTask(with: request, completionHandler: { data, response, _ in
        var info: AyuIpAddressInfo?
        if let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode), let data {
            info = AyuIpAddressInfo.parse(ipAddress: ipAddress, response: data)
        }
        DispatchQueue.main.async {
            if ayuIpAddressInfoCache.count >= 100 {
                ayuIpAddressInfoCache.removeAll()
            }
            ayuIpAddressInfoCache[ipAddress] = (info, CFAbsoluteTimeGetCurrent())
            completion(info)
        }
    }).resume()
}

extension ChatControllerImpl {
    func ayuPresentIpAddressInfo(ipAddress: String) {
        ayuRequestIpAddressInfo(ipAddress, completion: { [weak self] info in
            guard let self else {
                return
            }
            let presentationData = self.presentationData
            let lang = presentationData.strings.baseLanguageCode
            var text: String
            if let info {
                let rows: [(String, String)] = [
                    (i18n("Extera.IpInfo.Country", lang), info.location),
                    (i18n("Extera.IpInfo.Isp", lang), info.isp),
                    (i18n("Extera.IpInfo.Organization", lang), info.organization),
                    (i18n("Extera.IpInfo.Domain", lang), info.domain),
                    (i18n("Extera.IpInfo.TimeZone", lang), info.timezone)
                ]
                text = rows.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
                if text.isEmpty {
                    text = i18n("Extera.IpInfo.Unavailable", lang)
                }
            } else {
                text = i18n("Extera.IpInfo.Unavailable", lang)
            }
            var actions: [TextAlertAction] = []
            if info != nil {
                actions.append(TextAlertAction(type: .genericAction, title: presentationData.strings.Conversation_ContextMenuCopy, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    UIPasteboard.general.string = (info?.ip ?? ipAddress) + "\n" + text
                    self.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: self.presentationData.strings.Conversation_TextCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                }))
            }
            actions.append(TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {}))
            self.present(textAlertController(context: self.context, title: info?.ip ?? ipAddress, text: text, actions: actions), in: .window(.root))
        })
    }
}
