import SGSimpleSettings // MARK: Swiftgram
import SGLogging // MARK: Swiftgram
import SGGTranslate
import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import NaturalLanguage
import TelegramCore
import SwiftUI
import Translation
import Combine

// Incuding at least one Objective-C class in a swift file ensures that it doesn't get stripped by the linker
private final class LinkHelperClass: NSObject {
}

public var supportedTranslationLanguages = [
    "af",
    "sq",
    "am",
    "ar",
    "hy",
    "az",
    "eu",
    "be",
    "bn",
    "bs",
    "bg",
    "ca",
    "ceb",
    "zh",
    "co",
    "hr",
    "cs",
    "da",
    "nl",
    "en",
    "eo",
    "et",
    "fi",
    "fr",
    "fy",
    "gl",
    "ka",
    "de",
    "el",
    "gu",
    "ht",
    "ha",
    "haw",
    "he",
    "hi",
    "hmn",
    "hu",
    "is",
    "ig",
    "id",
    "ga",
    "it",
    "ja",
    "jv",
    "kn",
    "kk",
    "km",
    "rw",
    "ko",
    "ku",
    "ky",
    "lo",
    "lv",
    "lt",
    "lb",
    "mk",
    "mg",
    "ms",
    "ml",
    "mt",
    "mi",
    "mr",
    "mn",
    "my",
    "ne",
    "no",
    "ny",
    "or",
    "ps",
    "fa",
    "pl",
    "pt",
    "pt-BR",
    "pa",
    "ro",
    "ru",
    "sm",
    "gd",
    "sr",
    "st",
    "sn",
    "sd",
    "si",
    "sk",
    "sl",
    "so",
    "es",
    "su",
    "sw",
    "sv",
    "tl",
    "tg",
    "ta",
    "tt",
    "te",
    "th",
    "tr",
    "tk",
    "uk",
    "ur",
    "ug",
    "uz",
    "vi",
    "cy",
    "xh",
    "yi",
    "yo",
    "zu"
]

public var popularTranslationLanguages = [
    "en",
    "ar",
    "zh",
    "fr",
    "de",
    "it",
    "ja",
    "ko",
    "pt-BR",
    "ru",
    "es",
    "uk"
]

public func effectiveIgnoredTranslationLanguages(context: AccountContext, ignoredLanguages: [String]?) -> Set<String> {
    var baseLang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
    let rawSuffix = "-raw"
    if baseLang.hasSuffix(rawSuffix) {
        baseLang = String(baseLang.dropLast(rawSuffix.count))
    }
    baseLang = normalizeTranslationLanguage(baseLang) // MARK: Swiftgram
    
    var dontTranslateLanguages = Set<String>()
    if let ignoredLanguages = ignoredLanguages {
        dontTranslateLanguages = Set(ignoredLanguages)
    } else {
        dontTranslateLanguages.insert(baseLang)
        for language in systemLanguageCodes() {
            dontTranslateLanguages.insert(language)
        }
    }
    return dontTranslateLanguages
}

public func canTranslateChats(context: AccountContext) -> Bool {
    let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
    var chatTranslationAvailable = true
    switch translationConfiguration.auto {
    case .system:
        if #available(iOS 18.0, *) {
        } else {
            chatTranslationAvailable = false
        }
    case .alternative, .disabled:
        chatTranslationAvailable = false
    default:
        break
    }
    return chatTranslationAvailable || true // MARK: Swiftgram
}

public func canTranslateText(context: AccountContext, text: String, showTranslate: Bool, showTranslateIfTopical: Bool = false, ignoredLanguages: [String]?) -> (canTranslate: Bool, language: String?) {
    guard showTranslate || showTranslateIfTopical, text.count > 0 else {
        return (false, nil)
    }

    let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
    var translateButtonAvailable = false
    switch translationConfiguration.manual {
    case .enabled, .alternative:
        translateButtonAvailable = true
    case .system:
        if #available(iOS 18.0, *) {
            translateButtonAvailable = true
        }
    default:
        break
    }
    translateButtonAvailable = true // MARK: Swiftgram
    let showTranslate = showTranslate && translateButtonAvailable
        
    if #available(iOS 12.0, *) {
        if context.sharedContext.immediateExperimentalUISettings.disableLanguageRecognition {
            return (true, nil)
        }
                
        let dontTranslateLanguages = effectiveIgnoredTranslationLanguages(context: context, ignoredLanguages: ignoredLanguages)
        
        let text = String(text.prefix(64))
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(text)
        let hypotheses = languageRecognizer.languageHypotheses(withMaximum: 3)
        languageRecognizer.reset()
        
        var supportedTranslationLanguages = supportedTranslationLanguages
        if !showTranslate && showTranslateIfTopical {
            supportedTranslationLanguages = ["uk", "ru"]
        }
                
        let filteredLanguages = hypotheses.filter { supportedTranslationLanguages.contains(normalizeTranslationLanguage($0.key.rawValue)) }.sorted(by: { $0.value > $1.value })
        if let language = filteredLanguages.first {
            let languageCode = normalizeTranslationLanguage(language.key.rawValue)
            return (!dontTranslateLanguages.contains(languageCode), languageCode)
        } else {
            return (false, nil)
        }
    } else {
        return (false, nil)
    }
}

public func systemLanguageCodes() -> [String] {
    var languages: [String] = []
    for language in Locale.preferredLanguages.prefix(2) {
        let language = language.components(separatedBy: "-").first ?? language
        languages.append(language)
    }
    if languages.count == 2 && languages != ["en", "ru"] {
        languages = Array(languages.prefix(1))
    }
    return languages
}

@available(iOS 13.0, *)
class ExternalTranslationTrigger: ObservableObject {
    @Published var shouldInvalidate: Int = 0
}

@available(iOS 18.0, *)
private struct TranslationViewImpl: View {
    @State private var configuration: TranslationSession.Configuration?
    @ObservedObject var externalCondition: ExternalTranslationTrigger
    private let taskContainer: Atomic<ExperimentalInternalTranslationServiceImpl.TranslationTaskContainer>
    
    init(externalCondition: ExternalTranslationTrigger, taskContainer: Atomic<ExperimentalInternalTranslationServiceImpl.TranslationTaskContainer>) {
        self.externalCondition = externalCondition
        self.taskContainer = taskContainer
    }
    
    var body: some View {
        Text("ABC")
        .onChange(of: self.externalCondition.shouldInvalidate) { _ in
            let firstTaskLanguagePair = self.taskContainer.with { taskContainer -> (String, String)? in
                // Reconfiguring a session while it is translating cancels the active
                // SwiftUI task. Its completion would otherwise strand this queue.
                guard !taskContainer.isProcessing else {
                    return nil
                }
                if let firstTask = taskContainer.tasks.first {
                    return (firstTask.fromLang, firstTask.toLang)
                } else {
                    return nil
                }
            }
            
            if let firstTaskLanguagePair {
                // MARK: Swiftgram
                if let configuration = self.configuration, (configuration.source?.languageCode?.identifier ?? "") == firstTaskLanguagePair.0, configuration.target?.languageCode?.identifier == firstTaskLanguagePair.1 {
                    self.configuration?.invalidate()
                } else {
                    self.configuration = .init(
                        source: firstTaskLanguagePair.0.isEmpty ? nil : Locale.Language(identifier: firstTaskLanguagePair.0),
                        target: Locale.Language(identifier: firstTaskLanguagePair.1)
                    )
                }
                //
            }
        }
        .translationTask(self.configuration, action: { session in
            var task: ExperimentalInternalTranslationServiceImpl.TranslationTask?
            task = self.taskContainer.with { taskContainer -> ExperimentalInternalTranslationServiceImpl.TranslationTask? in
                if !taskContainer.tasks.isEmpty {
                    taskContainer.isProcessing = true
                    return taskContainer.tasks.removeFirst()
                } else {
                    return nil
                }
            }
            
            guard let task else {
                return
            }
            
            do {
                var nextClientIdentifier: Int = 0
                var clientIdentifierMap: [String: AnyHashable] = [:]
                let translationRequests = task.texts.map { key, value in
                    let id = nextClientIdentifier
                    nextClientIdentifier += 1
                    clientIdentifierMap["\(id)"] = key
                    return TranslationSession.Request(sourceText: value, clientIdentifier: "\(id)")
                }
                
                let work = Task {
                    try await session.translations(from: translationRequests)
                }
                task.cancellation.set(ActionDisposable {
                    work.cancel()
                })
                let responses = try await work.value
                var resultMap: [AnyHashable: String] = [:]
                for response in responses {
                    if let clientIdentifier = response.clientIdentifier, let originalKey = clientIdentifierMap[clientIdentifier] {
                        resultMap[originalKey] = "\(response.targetText)"
                    }
                }
                
                if !task.isCancelled.with({ $0 }) {
                    task.completion(resultMap)
                }
            } catch let e {
                // MARK: Swiftgram
                if SGSimpleSettings.shared.translatorLogsEnabled {
                    SGLogger.shared.log("Translate", "[\(SGSimpleSettings.TranslationBackend.system.rawValue)] error translating \(task.texts.values.reduce(0) { $0 + $1.count }) chars\(task.fromLang.isEmpty ? "" : " from '\(task.fromLang)'") to '\(task.toLang)', error: \(e)")
                }
                //
                if !task.isCancelled.with({ $0 }) {
                    task.completion(nil)
                }
            }
            
            let firstTaskLanguagePair = self.taskContainer.with { taskContainer -> (String, String)? in
                taskContainer.isProcessing = false
                if let firstTask = taskContainer.tasks.first {
                    return (firstTask.fromLang, firstTask.toLang)
                } else {
                    return nil
                }
            }
            
            if let firstTaskLanguagePair {
                // MARK: Swiftgram
                if let configuration = self.configuration, (configuration.source?.languageCode?.identifier ?? "") == firstTaskLanguagePair.0, configuration.target?.languageCode?.identifier == firstTaskLanguagePair.1 {
                    self.configuration?.invalidate()
                } else {
                    self.configuration = .init(
                        source: firstTaskLanguagePair.0.isEmpty ? nil : Locale.Language(identifier: firstTaskLanguagePair.0),
                        target: Locale.Language(identifier: firstTaskLanguagePair.1)
                    )
                }
                //
            }
        })
    }
}

@available(iOS 18.0, *)
public final class ExperimentalInternalTranslationServiceImpl: ExperimentalInternalTranslationService {
    fileprivate final class TranslationTask {
        let id: Int
        let texts: [AnyHashable: String]
        let fromLang: String
        let toLang: String
        let completion: ([AnyHashable: String]?) -> Void
        let isCancelled = Atomic(value: false)
        let cancellation = MetaDisposable()
        
        init(id: Int, texts: [AnyHashable: String], fromLang: String, toLang: String, completion: @escaping ([AnyHashable: String]?) -> Void) {
            self.id = id
            self.texts = texts
            self.fromLang = fromLang
            self.toLang = toLang
            self.completion = completion
        }
    }
    
    fileprivate final class TranslationTaskContainer {
        var tasks: [TranslationTask] = []
        var isProcessing = false
        
        init() {
        }
    }
    
    private final class Impl {
        private let hostingController: UIViewController
        
        private let taskContainer = Atomic(value: TranslationTaskContainer())
        private let taskTrigger = ExternalTranslationTrigger()
        
        private var nextId: Int = 0
        
        init(view: UIView) {
            self.hostingController = UIHostingController(rootView: TranslationViewImpl(
                externalCondition: self.taskTrigger,
                taskContainer: self.taskContainer
            ))
            
            view.addSubview(self.hostingController.view)
        }
        
        func translate(texts: [AnyHashable: String], fromLang: String, toLang: String, onResult: @escaping ([AnyHashable: String]?) -> Void) -> Disposable {
            guard !texts.isEmpty else {
                onResult([:])
                return EmptyDisposable
            }
            let id = self.nextId
            self.nextId += 1
            let task = TranslationTask(id: id, texts: texts, fromLang: fromLang, toLang: toLang, completion: onResult)
            self.taskContainer.with { taskContainer in
                taskContainer.tasks.append(task)
            }
            self.taskTrigger.shouldInvalidate += 1
            
            return ActionDisposable { [weak self] in
                _ = task.isCancelled.swap(true)
                task.cancellation.dispose()
                Queue.mainQueue().async {
                    guard let self else {
                        return
                    }
                    self.taskContainer.with { taskContainer in
                        taskContainer.tasks.removeAll(where: { $0.id == id })
                    }
                }
            }
        }
    }
    
    private let impl: QueueLocalObject<Impl>
    
    public init(view: UIView) {
        self.impl = QueueLocalObject(queue: .mainQueue(), generate: {
            return Impl(view: view)
        })
    }
    
    public func translate(texts: [AnyHashable: String], fromLang: String, toLang: String) -> Signal<[AnyHashable: String]?, NoError> {
        return self.impl.signalWith { impl, subscriber in
            return impl.translate(texts: texts, fromLang: fromLang, toLang: toLang, onResult: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
        }
        // A hosting view that disappears or a stalled language-model download
        // must eventually release callers so their provider fallback can run.
        |> timeout(90.0, queue: .mainQueue(), alternate: .single(nil))
    }
}

func alternativeTranslateText(text: String, fromLang: String?, toLang: String) -> Signal<(String, [MessageTextEntity])?, TelegramCore.TranslationError> {
    return gtranslate(text, toLang, fromLang: fromLang)
    |> map { text -> (String, [MessageTextEntity])? in (text, []) }
    |> mapError { error -> TelegramCore.TranslationError in
        switch error {
        case .network: return .generic
        case .limitExceeded: return .limitExceeded
        }
    }
}

func getRandomUserAgent() -> String {
    let userAgents = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1"
    ]
    return userAgents.randomElement() ?? userAgents[0]
}
