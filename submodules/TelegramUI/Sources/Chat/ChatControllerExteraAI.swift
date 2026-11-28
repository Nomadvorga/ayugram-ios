import AccountContext
import ChatInterfaceState
import ChatPresentationInterfaceState
import Display
import Foundation
import PresentationDataUtils
import SGSettingsUI
import SGSimpleSettings
import TelegramCore

extension ChatControllerImpl {
    /// Intercepts only the explicit composer AI action when the custom editor is
    /// selected. Opening the screen leaves the draft intact and sends nothing.
    func openExteraAIComposeIfEnabled() -> Bool {
        let configuration = ExteraAISettings.shared.configuration
        guard configuration.replacesTelegramEditor(isPremium: self.context.isPremium) else { return false }
        guard configuration.showEditor, self.exteraAIComposerCanWrite else {
            self.presentExteraAIComposerError("The AI editor is unavailable for this chat.", "Редактор ИИ недоступен в этом чате.")
            return true
        }
        let snapshot = self.chatDisplayNode.textInputPanelNode?.inputTextState ?? self.presentationInterfaceState.interfaceState.effectiveInputState
        guard !snapshot.content.isEmpty else { return true }
        // The REST editor accepts entity-expressible text. Never flatten a rich
        // draft containing media, tables or other structured blocks into text.
        guard snapshot.content.isEntityExpressible() else {
            self.presentExteraAIComposerError("This AI service accepts plain text. Your rich draft has been kept unchanged.", "Этот сервис ИИ принимает обычный текст. Черновик с расширенным форматированием сохранён без изменений.")
            return true
        }
        let location = self.chatLocation
        let editMessageId = self.presentationInterfaceState.interfaceState.editMessage?.messageId
        let controller = exteraAITextProcessingController(context: self.context, text: snapshot.content.plainText, action: .improve, applyResult: { [weak self] result in
            guard let self, self.isNodeLoaded, self.chatLocation == location,
                  ExteraAISettings.shared.configuration.showEditor,
                  ExteraAISettings.shared.configuration.replacesTelegramEditor(isPremium: self.context.isPremium),
                  self.exteraAIComposerCanWrite else {
                throw ExteraAIError.configuration("You can no longer insert text into this chat. The AI result is still available to copy.")
            }
            let current = self.chatDisplayNode.textInputPanelNode?.inputTextState ?? self.presentationInterfaceState.interfaceState.effectiveInputState
            guard current.content == snapshot.content, self.presentationInterfaceState.interfaceState.editMessage?.messageId == editMessageId else {
                throw ExteraAIError.configuration("The draft changed while AI was open. Your draft has been kept; copy the result or reopen AI with the new draft.")
            }
            switch result {
            case .empty:
                throw ExteraAIError.configuration("The AI result is empty. Your draft has been kept.")
            case .plain, .rich:
                // This is the same entity/rich-content adapter used by the native
                // TextProcessingScreen. Quote ranges stay in UTF-16 throughout.
                let inputState = chatTextInputState(fromComposedRichMessage: result)
                if let maximum = self.presentationInterfaceState.interfaceState.editMessage?.inputTextMaxLength,
                   inputState.content.length > Int(maximum) {
                    throw ExteraAIError.configuration("The result exceeds this message's text limit. Your draft has been kept.")
                }
                self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                    state.updatedInterfaceState { $0.withUpdatedEffectiveInputState(inputState) }.updatedInputMode { _ in .text }
                })
                return
            }
        })
        self.push(controller)
        return true
    }

    /// "Generate" of a message's menu: the AI chat with the message text as the prompt. Apply puts the answer
    /// into an empty message field; a draft or a message being edited is never replaced.
    func openExteraAIGenerate(prompt: String) {
        let location = self.chatLocation
        guard self.exteraAIComposerCanWrite else {
            self.push(exteraAIChatController(context: self.context, initialPrompt: prompt, applyResult: nil))
            return
        }
        self.push(exteraAIChatController(context: self.context, initialPrompt: prompt, applyResult: { [weak self] result in
            guard let self, self.isNodeLoaded, self.chatLocation == location, self.exteraAIComposerCanWrite else {
                throw ExteraAIError.configuration("You can no longer insert text into this chat. The AI result is still available to copy.")
            }
            let current = self.chatDisplayNode.textInputPanelNode?.inputTextState ?? self.presentationInterfaceState.interfaceState.effectiveInputState
            guard self.presentationInterfaceState.interfaceState.editMessage == nil, current.content.isEmpty else {
                throw ExteraAIError.configuration("The message field already has text. It has been kept; copy the result instead.")
            }
            guard case .plain = result else {
                throw ExteraAIError.configuration("The AI result is empty.")
            }
            let inputState = chatTextInputState(fromComposedRichMessage: result)
            guard !inputState.content.isEmpty else {
                throw ExteraAIError.configuration("The AI result is empty.")
            }
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                state.updatedInterfaceState { $0.withUpdatedEffectiveInputState(inputState) }.updatedInputMode { _ in .text }
            })
        }))
    }

    private var exteraAIComposerCanWrite: Bool {
        let state = self.presentationInterfaceState
        if let group = state.renderedPeer?.peer as? TelegramGroup, group.hasBannedPermission(.banSendText) {
            return false
        }
        if let channel = state.renderedPeer?.peer as? TelegramChannel,
           channel.hasBannedPermission(.banSendText, ignoreDefault: canBypassRestrictions(chatPresentationInterfaceState: state)) != nil {
            return false
        }
        return !self.context.isFrozen && !state.isNotAccessible && canSendMessagesToChat(state) && !state.isPremiumRequiredForMessaging && state.threadData?.isClosed != true && state.isGeneralThreadClosed != true && !state.copyProtectionEnabled && !state.myCopyProtectionEnabled
    }

    private func presentExteraAIComposerError(_ english: String, _ russian: String) {
        let text = self.presentationData.strings.baseLanguageCode.hasPrefix("ru") ? russian : english
        self.present(textAlertController(context: self.context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
    }
}
