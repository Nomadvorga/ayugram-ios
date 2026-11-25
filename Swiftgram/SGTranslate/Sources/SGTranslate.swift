import SGGTranslate
import SGLogging
import SGSimpleSettings

import Postbox
import SwiftSignalKit

public class QuickTranslationMessageAttribute: MessageAttribute, Equatable {
    public let originalText: String
    public let originalEntities: [MessageTextEntity]

    public var associatedPeerIds: [PeerId] {
        return []
    }

    public init(text: String, entities: [MessageTextEntity]) {
        self.originalText = text
        self.originalEntities = entities
    }

    required public init(decoder: PostboxDecoder) {
        self.originalText = decoder.decodeStringForKey("originalText", orElse: "")
        self.originalEntities = decoder.decodeObjectArrayWithDecoderForKey("originalEntities")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.originalText, forKey: "originalText")
        encoder.encodeObjectArray(self.originalEntities, forKey: "originalEntities")
    }

    public static func ==(lhs: QuickTranslationMessageAttribute, rhs: QuickTranslationMessageAttribute) -> Bool {
        if lhs.originalText != rhs.originalText {
            return false
        }
        if lhs.originalEntities != rhs.originalEntities {
            return false
        }
        return true
    }
}

func sgTranslationDebugLog(_ message: @autoclosure () -> String) {
    guard SGSimpleSettings.shared.translatorLogsEnabled else {
        return
    }
    SGLogger.shared.log("Translate", message())
}

func sgTranslationDebugLanguages(fromLang: String?, toLang: String) -> String {
    if let fromLang {
        return " from '\(fromLang)' to '\(toLang)'"
    }
    return " to '\(toLang)'"
}

func sgTranslationDebugSuccess(backend: SGSimpleSettings.TranslationBackend, inputLength: Int, outputLength: Int, fromLang: String?, toLang: String) {
    sgTranslationDebugLog("[\(backend.rawValue)] translated \(inputLength) chars\(sgTranslationDebugLanguages(fromLang: fromLang, toLang: toLang)) \(outputLength) chars")
}

func sgTranslationDebugError(backend: SGSimpleSettings.TranslationBackend, inputLength: Int, fromLang: String?, toLang: String, error: Any) {
    sgTranslationDebugLog("[\(backend.rawValue)] error translating \(inputLength) chars\(sgTranslationDebugLanguages(fromLang: fromLang, toLang: toLang)), error: \(error)")
}

func sgTranslationDebugFallback(backend: SGSimpleSettings.TranslationBackend, inputLength: Int, fromLang: String?, toLang: String) {
    sgTranslationDebugLog("[\(backend.rawValue)] attempting GTranslate fallback for \(inputLength) chars\(sgTranslationDebugLanguages(fromLang: fromLang, toLang: toLang))")
}

func sgGTranslate(text: String, fromLang: String? = nil, toLang: String) -> Signal<(String, [MessageTextEntity])?, TranslationError> {
    return gtranslate(text, toLang, fromLang: fromLang)
    |> map { translatedText in
        sgTranslationDebugSuccess(backend: .gtranslate, inputLength: text.count, outputLength: translatedText.count, fromLang: fromLang, toLang: toLang)
        return (translatedText, [])
    }
    |> mapError { error in
        sgTranslationDebugError(backend: .gtranslate, inputLength: text.count, fromLang: fromLang, toLang: toLang, error: error)
        switch error {
        case .network: return .generic
        case .limitExceeded: return .limitExceeded
        }
    }
}

func sgWrappedTranslateSingle(text: String, toLang: String, `default`: Signal<(String, [MessageTextEntity])?, TranslationError>) -> Signal<(String, [MessageTextEntity])?, TranslationError> {
    let backend = SGSimpleSettings.shared.translationBackendEnum
    switch backend {
    case .gtranslate:
        return sgGTranslate(text: text, toLang: toLang)
    case .microsoft:
        return sgMicrosoftTranslate(texts: [text], toLang: toLang)
        |> map { result -> (String, [MessageTextEntity])? in
            result.first
        }
        |> mapError { error in
            sgTranslationDebugError(backend: .microsoft, inputLength: text.count, fromLang: nil, toLang: toLang, error: error)
            return error
        }
    case .yandex:
        return sgYandexTranslate(texts: [text], toLang: toLang)
        |> map { result -> (String, [MessageTextEntity])? in
            result.first
        }
        |> mapError { error in
            sgTranslationDebugError(backend: .yandex, inputLength: text.count, fromLang: nil, toLang: toLang, error: error)
            return error
        }
    case .system:
        guard let engineExperimentalInternalTranslationService else {
            sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: nil, toLang: toLang, error: "unavailable")
            sgTranslationDebugFallback(backend: backend, inputLength: text.count, fromLang: nil, toLang: toLang)
            return sgGTranslate(text: text, toLang: toLang)
        }
        return engineExperimentalInternalTranslationService.translate(texts: [0: text], fromLang: "", toLang: toLang)
        |> castError(TranslationError.self)
        |> mapToSignal { result -> Signal<(String, [MessageTextEntity])?, TranslationError> in
            guard let translatedText = result?[0], !translatedText.isEmpty else {
                sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: nil, toLang: toLang, error: "incompleteResult")
                return .fail(.generic)
            }
            sgTranslationDebugSuccess(backend: backend, inputLength: text.count, outputLength: translatedText.count, fromLang: nil, toLang: toLang)
            return .single((translatedText, []))
        }
        |> `catch` { error in
            sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: nil, toLang: toLang, error: error)
            sgTranslationDebugFallback(backend: backend, inputLength: text.count, fromLang: nil, toLang: toLang)
            return sgGTranslate(text: text, toLang: toLang)
        }
    case .default:
        return `default`
        |> beforeNext { result in
            sgTranslationDebugSuccess(backend: backend, inputLength: text.count, outputLength: result?.0.count ?? 0, fromLang: nil, toLang: toLang)
        }
        |> `catch` { error in
            sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: nil, toLang: toLang, error: error)
            sgTranslationDebugFallback(backend: backend, inputLength: text.count, fromLang: nil, toLang: toLang)
            return sgGTranslate(text: text, toLang: toLang)
        }
    }
}

func sgGTranslate(texts: [(String, [MessageTextEntity])], fromLang: String? = nil, toLang: String) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    var signal: Signal<[(String, [MessageTextEntity])], TranslationError> = .single([])
    for (text, _) in texts {
        signal = signal |> mapToSignal { accumulated in
            return sgGTranslate(text: text, fromLang: fromLang, toLang: toLang)
            |> mapToSignal { translated -> Signal<[(String, [MessageTextEntity])], TranslationError> in
                guard let translated else {
                    return .fail(.generic)
                }
                return .single(accumulated + [translated])
            }
        }
    }
    return signal
}

func sgMicrosoftTranslate(texts: [(String, [MessageTextEntity])], fromLang: String? = nil, toLang: String) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    return sgMicrosoftTranslate(texts: texts.map { $0.0 }, fromLang: fromLang, toLang: toLang)
}

func sgYandexTranslate(texts: [(String, [MessageTextEntity])], fromLang: String? = nil, toLang: String) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    return sgYandexTranslate(texts: texts.map { $0.0 }, fromLang: fromLang, toLang: toLang)
}

func sgWrappedTranslateMultiple(texts: [(String, [MessageTextEntity])], fromLang: String? = nil, toLang: String, `default`: Signal<[(String, [MessageTextEntity])], TranslationError>) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    guard !texts.isEmpty else {
        return .single([])
    }
    let backend = SGSimpleSettings.shared.translationBackendEnum
    switch backend {
    case .gtranslate:
        return sgGTranslate(texts: texts, fromLang: fromLang, toLang: toLang)
    case .microsoft:
        return sgMicrosoftTranslate(texts: texts, fromLang: fromLang, toLang: toLang)
        |> mapError { error in
            sgTranslationDebugError(backend: .microsoft, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang, error: error)
            return error
        }
    case .yandex:
        return sgYandexTranslate(texts: texts, fromLang: fromLang, toLang: toLang)
        |> mapError { error in
            sgTranslationDebugError(backend: .yandex, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang, error: error)
            return error
        }
    case .system:
        guard let engineExperimentalInternalTranslationService else {
            sgTranslationDebugError(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang, error: "unavailable")
            sgTranslationDebugFallback(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang)
            return sgGTranslate(texts: texts, fromLang: fromLang, toLang: toLang)
        }
        let sourceTexts = Dictionary(uniqueKeysWithValues: texts.enumerated().map { (AnyHashable($0.offset), $0.element.0) })
        return engineExperimentalInternalTranslationService.translate(texts: sourceTexts, fromLang: fromLang ?? "", toLang: toLang)
        |> castError(TranslationError.self)
        |> mapToSignal { result -> Signal<[(String, [MessageTextEntity])], TranslationError> in
            guard let result, result.count == texts.count else {
                sgTranslationDebugError(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang, error: "incompleteResult")
                return .fail(.generic)
            }
            let translated = texts.indices.compactMap { index -> (String, [MessageTextEntity])? in
                result[AnyHashable(index)].flatMap { $0.isEmpty ? nil : ($0, []) }
            }
            guard translated.count == texts.count else {
                sgTranslationDebugError(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang, error: "incompleteResult")
                return .fail(.generic)
            }
            sgTranslationDebugSuccess(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, outputLength: translated.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang)
            return .single(translated)
        }
        |> `catch` { error in
            sgTranslationDebugError(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang, error: error)
            sgTranslationDebugFallback(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang)
            return sgGTranslate(texts: texts, fromLang: fromLang, toLang: toLang)
        }
    case .default:
        return `default`
        |> beforeNext { translated in
            sgTranslationDebugSuccess(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, outputLength: translated.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang)
        }
        |> `catch` { error in
            sgTranslationDebugError(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang, error: error)
            sgTranslationDebugFallback(backend: backend, inputLength: texts.reduce(0) { $0 + $1.0.count }, fromLang: nil, toLang: toLang)
            return sgGTranslate(texts: texts, fromLang: fromLang, toLang: toLang)
        }
    }
}

func _internal_translateMessagesViaText(account: Account, messagesDict: [EngineMessage.Id: String], fromLang: String?, toLang: String, generateEntitiesFunction: @escaping (String) -> [MessageTextEntity], forceGTranslate: Bool) -> Signal<Never, TranslationError> {
    let entries = Array(messagesDict)
    guard !entries.isEmpty else {
        return .complete()
    }
    let texts = entries.map { ($0.value, [MessageTextEntity]()) }
    let signal: Signal<[(String, [MessageTextEntity])], TranslationError>
    if forceGTranslate {
        signal = sgGTranslate(texts: texts, fromLang: fromLang, toLang: toLang)
    } else {
        signal = sgWrappedTranslateMultiple(texts: texts, fromLang: fromLang, toLang: toLang, default: _internal_translateTexts(network: account.network, texts: texts, toLang: toLang, tone: .neutral))
    }
    return signal
    |> mapToSignal { translated -> Signal<Never, TranslationError> in
        guard translated.count == entries.count else {
            return .fail(.generic)
        }
        return account.postbox.transaction { transaction in
            for (entry, translated) in zip(entries, translated) where !translated.0.isEmpty {
                let messageId = entry.key
                transaction.updateMessage(messageId, update: { currentMessage in
                    // Do not attach an in-flight translation to a message edited
                    // while the provider was processing the original text.
                    let currentText = currentMessage.text.isEmpty ? (currentMessage.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute)?.text : currentMessage.text
                    guard currentText == entry.value else {
                        return .skip
                    }
                    let entities = translated.1.isEmpty ? generateEntitiesFunction(translated.0) : translated.1
                    let updatedAttribute = TranslationMessageAttribute(text: translated.0, entities: entities, toLang: toLang)
                    let storeForwardInfo = currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init)
                    var attributes = currentMessage.attributes.filter { !($0 is TranslationMessageAttribute) }
                    attributes.append(updatedAttribute)
                    return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
                })
            }
        }
        |> castError(TranslationError.self)
        |> ignoreValues
    }
}

func sgTranslateRawText(account: Account, text: String, fromLang: String?, toLang: String, forceGTranslate: Bool = false) -> Signal<(String, [MessageTextEntity])?, TranslationError> {
    guard !text.isEmpty else {
        return .complete()
    }
    let backend = SGSimpleSettings.shared.translationBackendEnum
    if forceGTranslate || backend == .gtranslate {
        return sgGTranslate(text: text, fromLang: fromLang, toLang: toLang)
    }
    if backend == .microsoft {
        return sgMicrosoftTranslate(texts: [text], fromLang: fromLang, toLang: toLang)
        |> map { result -> (String, [MessageTextEntity])? in
            result.first
        }
        |> mapError { error in
            sgTranslationDebugError(backend: .microsoft, inputLength: text.count, fromLang: fromLang, toLang: toLang, error: error)
            return error
        }
    }
    if backend == .yandex {
        return sgYandexTranslate(texts: [text], fromLang: fromLang, toLang: toLang)
        |> map { result -> (String, [MessageTextEntity])? in
            result.first
        }
        |> mapError { error in
            sgTranslationDebugError(backend: .yandex, inputLength: text.count, fromLang: fromLang, toLang: toLang, error: error)
            return error
        }
    }
    if backend == .system {
        guard let engineExperimentalInternalTranslationService else {
            sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: fromLang, toLang: toLang, error: "unavailable")
            sgTranslationDebugFallback(backend: backend, inputLength: text.count, fromLang: fromLang, toLang: toLang)
            return sgGTranslate(text: text, fromLang: fromLang, toLang: toLang)
        }
        return engineExperimentalInternalTranslationService.translate(texts: [0: text], fromLang: fromLang ?? "", toLang: toLang)
        |> castError(TranslationError.self)
        |> mapToSignal { result -> Signal<(String, [MessageTextEntity])?, TranslationError> in
            guard let translatedText = result?[0], !translatedText.isEmpty else {
                sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: fromLang, toLang: toLang, error: "incompleteResult")
                return .fail(.generic)
            }
            sgTranslationDebugSuccess(backend: backend, inputLength: text.count, outputLength: translatedText.count, fromLang: fromLang, toLang: toLang)
            return .single((translatedText, []))
        }
        |> `catch` { error in
            sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: fromLang, toLang: toLang, error: error)
            sgTranslationDebugFallback(backend: backend, inputLength: text.count, fromLang: fromLang, toLang: toLang)
            return sgGTranslate(text: text, fromLang: fromLang, toLang: toLang)
        }
    }
    return _internal_translate(network: account.network, text: text, toLang: toLang)
    |> beforeNext { result in
        sgTranslationDebugSuccess(backend: backend, inputLength: text.count, outputLength: result?.0.count ?? 0, fromLang: fromLang, toLang: toLang)
    }
    |> `catch` { error in
        sgTranslationDebugError(backend: backend, inputLength: text.count, fromLang: fromLang, toLang: toLang, error: error)
        sgTranslationDebugFallback(backend: backend, inputLength: text.count, fromLang: fromLang, toLang: toLang)
        return sgGTranslate(text: text, fromLang: fromLang, toLang: toLang)
    }
}

extension TelegramEngine.Messages {
    public func translateMessagesViaText(messagesDict: [EngineMessage.Id: String], fromLang: String?, toLang: String, generateEntitiesFunction: @escaping (String) -> [MessageTextEntity], enableLocalIfPossible: Bool, forceGTranslate: Bool = false) -> Signal<Never, TranslationError> {
        return _internal_translateMessagesViaText(account: self.account, messagesDict: messagesDict, fromLang: fromLang, toLang: toLang, generateEntitiesFunction: generateEntitiesFunction, forceGTranslate: forceGTranslate)
    }
}
