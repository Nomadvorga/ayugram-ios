import Foundation
import Display
import AccountContext
import PresentationDataUtils
import SGSimpleSettings
import SGStrings

// MARK: AyuGram
extension ChatControllerImpl {
    // "Send Confirmations": returns true when sending waits for the answer; on "Yes" send runs again, unasked.
    func ayuConfirmSending(_ kind: AyuSendConfirmations.Kind, send: @escaping () -> Void) -> Bool {
        if self.ayuSendIsConfirmed || !AyuSendConfirmations.shared.isEnabled(kind) {
            return false
        }
        let presentationData = self.presentationData
        let lang = presentationData.strings.baseLanguageCode
        let textKey: String
        switch kind {
        case .sticker:
            textKey = "Ayu.ConfirmationSticker"
        case .gif:
            textKey = "Ayu.ConfirmationGIF"
        case .voice:
            textKey = "Ayu.ConfirmationVoice"
        case .round:
            textKey = "Ayu.ConfirmationRound"
        }
        self.present(textAlertController(context: self.context, title: nil, text: i18n(textKey, lang), actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_No, action: {}),
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_Yes, action: { [weak self] in
                guard let self else {
                    return
                }
                self.ayuSendIsConfirmed = true
                send()
                self.ayuSendIsConfirmed = false
            })
        ]), in: .window(.root))
        return true
    }
}
