import SGSimpleSettings
import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import SwiftSignalKit
import AccountContext
import SwiftUI
import TelegramUIPreferences
import Pasteboard

/// Initial translation options passed through the shared screen factory without
/// introducing a dependency from TranslateUI on the concrete TextProcessingScreen.
public final class TranslationScreenOptions {
    public let toLanguage: String?
    public let ignoredLanguages: [String]?
    public let wasDismissed: (() -> Void)?

    public init(toLanguage: String?, ignoredLanguages: [String]?, wasDismissed: (() -> Void)?) {
        self.toLanguage = toLanguage
        self.ignoredLanguages = ignoredLanguages
        self.wasDismissed = wasDismissed
    }
}

/// Implemented by the concrete screen returned by SharedAccountContext's factory.
public protocol TranslationScreenOptionsConsumer: AnyObject {
    func setTranslationScreenOptions(_ options: TranslationScreenOptions)
}

/// The configured default for both single-message and whole-chat translation.
public func defaultTranslationTargetLanguage(_ baseLanguageCode: String) -> String {
    return ExteraSettings.shared.effectiveTranslationTargetLanguage(baseLanguageCode)
}

public func presentTranslateScreen(
    context: AccountContext,
    text: String,
    entities: [MessageTextEntity] = [],
    canCopy: Bool,
    fromLanguage: String?,
    toLanguage: String? = nil,
    isExpanded: Bool = false,
    ignoredLanguages: [String]? = nil,
    replaceText: ((String, [MessageTextEntity]) -> Void)? = nil,
    translateChat: ((String, String) -> Void)? = nil,
    pushController: @escaping (ViewController) -> Void = { _ in },
    presentController: @escaping (ViewController) -> Void = { _ in },
    wasDismissed: (() -> Void)? = nil,
    display: @escaping (ViewController) -> Void
) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
    }
    let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
    var useSystemTranslation = false
    switch SGSimpleSettings.shared.translationBackendEnum {
    case .system:
        useSystemTranslation = true
    case .default:
        if case .system = translationConfiguration.manual {
            useSystemTranslation = true
        }
    case .gtranslate, .microsoft, .yandex:
        break
    }

    if useSystemTranslation, presentSystemTranslateScreen(context: context, text: text, wasDismissed: wasDismissed) {
        return
    }
    // SharedAccountContext owns the factory to avoid a TranslateUI -> TelegramUI
    // dependency cycle. It returns the same native screen used by text selection.
    Task { @MainActor in
        let applyResult: ((ComposedRichMessage) -> Void)? = replaceText.map { replaceText in
            return { result in
                if case let .plain(text, entities) = result {
                    replaceText(text, entities)
                }
            }
        }
        let copyResult: ((ComposedRichMessage) -> Void)?
        if canCopy {
            copyResult = { result in
                if case let .plain(text, entities) = result {
                    storeMessageTextInPasteboard(text, entities: entities)
                }
            }
        } else {
            copyResult = nil
        }
        let translateChatResult: ((String) -> Void)? = translateChat.map { translateChat in
            return { target in
                let source = fromLanguage ?? NSLinguisticTagger.dominantLanguage(for: text) ?? ""
                translateChat(source, target)
            }
        }
        let controller = await context.sharedContext.makeTextProcessingScreen(
            context: context,
            theme: nil,
            mode: .translate(fromLanguage: fromLanguage, applyResult: applyResult),
            inputText: .plain(text: text, entities: entities),
            copyResult: copyResult,
            translateChat: translateChatResult
        )
        (controller as? TranslationScreenOptionsConsumer)?.setTranslationScreenOptions(TranslationScreenOptions(toLanguage: toLanguage, ignoredLanguages: ignoredLanguages, wasDismissed: wasDismissed))
        display(controller)
    }
}

private func presentSystemTranslateScreen(context: AccountContext, text: String, wasDismissed: (() -> Void)?) -> Bool {
    if #available(iOS 18.0, *), let rootViewController = context.sharedContext.mainWindow?.viewController?.view.window?.rootViewController {
        var presentingController = rootViewController
        while let presentedController = presentingController.presentedViewController {
            guard !presentedController.isBeingDismissed else {
                return false
            }
            presentingController = presentedController
        }
        var dismissImpl: (() -> Void)?
        let pickerView = TranslateScreenHostingView(text: text, completionHandler: { [weak presentingController] in
            DispatchQueue.main.async(execute: {
                guard let presentedController = presentingController?.presentedViewController, presentedController.isBeingDismissed == false else { return }
                dismissImpl?()
            })
        })
        let hostingController = UIHostingController(rootView: pickerView)
        hostingController.view.isHidden = true
        hostingController.modalPresentationStyle = .overCurrentContext
        presentingController.present(hostingController, animated: true)
        dismissImpl = { [weak hostingController] in
            Queue.mainQueue().after(0.4, {
                hostingController?.dismiss(animated: false, completion: wasDismissed)
            })
        }
        return true
    }
    return false
}

@available(iOS 18.0, *)
struct TranslateScreenHostingView: View {
    @State var presented = true
    var text: String
    var handler: () -> Void
    
    init(text: String, completionHandler: @escaping () -> Void) {
        self.text = text
        self.handler = completionHandler
    }
    
    var body: some View {
        Spacer()
            .translationPresentation(
                isPresented: $presented,
                text: text
            )
            .onChange(of: presented) { newValue in
                if newValue == false {
                    handler()
                }
            }
    }
}
