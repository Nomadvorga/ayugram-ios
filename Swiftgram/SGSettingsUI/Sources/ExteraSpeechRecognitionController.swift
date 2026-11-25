import AccountContext
import Display
import Foundation
import ItemListUI
import LocalAudioTranscription
import SGItemListUI
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

private enum SpeechSection: Int32, SGItemListSection { case selection, options, models, languages, info }
private typealias SpeechEntry = SGItemListUIEntry<SpeechSection, Int, Int, Int, Int, Int>
private enum SpeechRow {
    case action(SpeechSection, String, () -> Void)
    case toggle(SpeechSection, String, Bool, (Bool) -> Void)
    case notice(SpeechSection, String)
}

/// Root settings entry point. Requires LocalAudioTranscription in SGSettingsUI's deps.
public func sgSpeechRecognitionController(context: AccountContext) -> ViewController {
    let page = SpeechRecognitionPage(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, page.refresh.get())
    |> deliverOnMainQueue
    |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rows = page.rows()
        let entries: [SpeechEntry] = rows.enumerated().map { index, row in
            switch row {
            case let .action(section, title, _):
                return .action(id: index, section: section, actionType: index, text: title, kind: .generic)
            case let .toggle(section, title, value, _):
                return .toggle(id: index, section: section, settingName: index, value: value, text: title, enabled: page.operation == nil)
            case let .notice(section, title):
                return .notice(id: index, section: section, text: title)
            }
        }
        let arguments = SGItemListArguments<Int, Int, Int, Int, Int>(context: context, visualStyle: .extera, setBoolValue: { index, value in
            guard page.operation == nil else { return }
            if rows.indices.contains(index), case let .toggle(_, _, _, update) = rows[index] { update(value) }
        }, action: { index in
            if rows.indices.contains(index), case let .action(_, _, action) = rows[index] { action() }
        })
        let state = ItemListControllerState(presentationData: ItemListPresentationData(data), title: .text(page.text("Speech Recognition", "Распознавание речи")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back))
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(data), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    page.controller = controller
    controller.didAppear = { [weak page] _ in page?.reload() }
    return controller
}

private final class SpeechRecognitionPage {
    let context: AccountContext
    weak var controller: ViewController?
    let refresh = ValuePromise(true, ignoreRepeated: false)
    private(set) var operation: Task<Void, Never>?
    private var query: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var models: [ExteraSpeechModel] = []
    private var loaded = false
    private var cancelling = false
    private var operationTitle = ""
    private var message: String?

    init(context: AccountContext) {
        self.context = context
        self.observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh.set(true) }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.query?.cancel()
        self.operation?.cancel()
    }

    func text(_ english: String, _ russian: String) -> String {
        return self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode.hasPrefix("ru") ? russian : english
    }

    private func languageName(_ identifier: String) -> String {
        let code = self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        return (Locale(identifier: code).localizedString(forIdentifier: identifier) ?? identifier) + " (\(identifier))"
    }

    func rows() -> [SpeechRow] {
        let settings = ExteraSpeechSettings.shared
        let config = settings.configuration
        var rows: [SpeechRow] = [
            .action(.selection, (config.selection == .disabled ? "✓ " : "") + self.text("None", "Нет"), { [weak self] in self?.select(.disabled) }),
            .action(.selection, (config.selection == .automatic ? "✓ " : "") + self.text("Automatic — chat/app language", "Авто — язык чата/приложения"), { [weak self] in self?.select(.automatic) })
        ]
        let mode = config.useManagedOfflineModel ? self.text("Apple offline model", "Модель Apple offline") : self.text("Apple Speech", "Apple Speech")
        rows.append(.notice(.selection, self.text("Local recognition: ", "Локальное распознавание: ") + (config.isEnabled ? mode + " · " + (config.localeIdentifier.isEmpty ? self.text("Automatic", "Авто") : self.languageName(config.localeIdentifier)) : self.text("Disabled", "Выключено"))))
        rows.append(.toggle(.options, self.text("Apple Speech: Require On-Device Recognition", "Apple Speech: только на устройстве"), config.onDeviceOnly, { value in ExteraTranslationSettings.shared.appleSpeechOnDeviceOnly = value }))
        rows.append(.notice(.options, self.text("Apple Speech may send audio to Apple when on-device-only is off. When on, unavailable local recognition fails. Managed offline models below always process audio on this device. None disables local recognition; Telegram server transcription is a separate backend.", "Apple Speech может отправлять аудио в Apple, если режим «только на устройстве» выключен. Когда он включён, недоступное локальное распознавание завершится ошибкой. Управляемые offline-модели ниже всегда обрабатывают аудио на устройстве. «Нет» выключает локальное распознавание; серверная расшифровка Telegram — отдельный движок.")))
        if #available(iOS 26.0, *) {
            if let operation = self.operation {
                rows.append(.notice(.models, self.operationTitle))
                rows.append(.action(.models, self.cancelling ? self.text("Cancelling…", "Отмена…") : self.text("Cancel Request", "Отменить запрос"), { [weak self] in
                    self?.cancelling = true
                    operation.cancel()
                    self?.refresh.set(true)
                }))
            } else {
                rows.append(.action(.models, self.text("Refresh Apple Offline Models", "Обновить список моделей Apple offline"), { [weak self] in self?.reload() }))
            }
            if !self.loaded {
                rows.append(.notice(.models, self.text("Loading model availability…", "Проверка доступности моделей…")))
            } else if self.models.isEmpty {
                rows.append(.notice(.models, self.text("Apple offline models are unavailable on this device.", "Модели Apple offline недоступны на этом устройстве.")))
            }
            for model in self.models {
                let selected = config.isEnabled && config.useManagedOfflineModel && ExteraSpeechLocalePolicy.normalized(config.localeIdentifier) == ExteraSpeechLocalePolicy.normalized(model.localeIdentifier)
                let status: String
                switch model.status {
                case .unsupported: status = self.text("Unavailable", "Недоступна")
                case .notInstalled: status = self.text("Not installed", "Не установлена")
                case .downloading: status = self.text("Downloading", "Загружается")
                case .installed: status = self.text("Installed", "Установлена")
                }
                let reservation = model.isReserved ? self.text(" · Kept for this app", " · Сохранена для приложения") : ""
                rows.append(.action(.models, (selected ? "✓ " : "") + self.languageName(model.localeIdentifier) + " · " + status + reservation, { [weak self] in self?.open(model) }))
            }
        } else {
            rows.append(.notice(.models, self.text("Explicit Apple model download and release require iOS 26 and a supported device. Earlier systems offer Apple Speech's on-device-only request, without public model management.", "Скачивание и освобождение моделей Apple требуют iOS 26 и поддерживаемого устройства. На более ранних системах доступен запрос Apple Speech «только на устройстве», без публичного управления моделями.")))
        }
        if let message = self.message { rows.append(.notice(.models, message)) }
        rows.append(.notice(.languages, self.text("Apple Speech language (selecting uses the legacy recognizer)", "Язык Apple Speech (выбор включает прежний распознаватель)")))
        var languages = supportedTranscriptionLanguages()
        if !config.localeIdentifier.isEmpty && !languages.contains(config.localeIdentifier) { languages.append(config.localeIdentifier) }
        for identifier in languages.sorted() {
            let selected = config.isEnabled && !config.useManagedOfflineModel && config.localeIdentifier == identifier
            rows.append(.action(.languages, (selected ? "✓ " : "") + self.languageName(identifier), { [weak self] in self?.select(.locale(identifier)) }))
        }
        rows.append(.notice(.info, self.text("Provider: Apple Speech, not Vosk. The language catalogue depends on this device and OS. Downloads start only after Download is pressed. Apple controls sizes, storage limits and shared assets. Release removes this app's reservation; iOS decides when shared files are deleted. Apple may retry a requested download later; cancelling requests cancellation and releases a newly acquired reservation. Models retained before a failed request remain retained.", "Провайдер: Apple Speech, не Vosk. Каталог языков зависит от устройства и ОС. Загрузка начинается только по кнопке «Скачать». Размеры, лимиты хранения и общие ресурсы контролирует Apple. «Освободить» снимает резервирование приложения; момент удаления общих файлов определяет iOS. Apple может повторить запрошенную загрузку позже; отмена запрашивает остановку и снимает новое резервирование. Модели, сохранённые до неудачного запроса, остаются сохранёнными.")))
        return rows
    }

    private func select(_ selection: ExteraSpeechLanguageSelection) {
        guard self.operation == nil else { return }
        ExteraSpeechSettings.shared.languageSelection = selection
        if selection != .disabled { SGSimpleSettings.shared.transcriptionBackend = SGSimpleSettings.TranscriptionBackend.apple.rawValue }
    }

    func reload() {
        guard #available(iOS 26.0, *), self.operation == nil, self.query == nil else { return }
        self.query = Task { [weak self] in
            let models = await ExteraSpeechModelManager.shared.catalogue()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.models = models
                self?.loaded = true
                self?.query = nil
                self?.refresh.set(true)
            }
        }
    }

    @available(iOS 26.0, *)
    private func open(_ model: ExteraSpeechModel) {
        guard self.operation == nil else { return }
        let alert = UIAlertController(title: self.languageName(model.localeIdentifier), message: self.text("Download retains an Apple model for this app. Use Model verifies its installed status again without downloading. Release removes the app's reservation; a selected released model will fail until downloaded again.", "«Скачать» сохраняет модель Apple для приложения. «Использовать» повторно проверяет установку без скачивания. «Освободить» снимает резервирование; выбранная освобождённая модель не работает до повторной загрузки."), preferredStyle: .alert)
        if model.status == .installed && model.isReserved {
            alert.addAction(UIAlertAction(title: self.text("Use Model Offline", "Использовать offline"), style: .default, handler: { [weak self] _ in self?.run(model, action: .use) }))
        }
        if model.status != .unsupported && !(model.status == .installed && model.isReserved) {
            let title = model.status == .installed ? self.text("Keep Model for This App", "Сохранить для приложения") : self.text("Download Model", "Скачать модель")
            alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in self?.run(model, action: .download) }))
        }
        if model.isReserved {
            alert.addAction(UIAlertAction(title: self.text("Release Model", "Освободить модель"), style: .destructive, handler: { [weak self] _ in self?.run(model, action: .release) }))
        }
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        self.controller?.present(alert, animated: true)
    }

    private enum ModelAction { case download, use, release }

    @available(iOS 26.0, *)
    private func run(_ model: ExteraSpeechModel, action: ModelAction) {
        guard self.operation == nil else { return }
        self.query?.cancel()
        self.query = nil
        self.message = nil
        self.cancelling = false
        self.operationTitle = self.languageName(model.localeIdentifier) + " · " + self.text("Working…", "Обработка…")
        let configuration = ExteraSpeechSettings.shared.configuration
        self.operation = Task { [weak self] in
            let manager = ExteraSpeechModelManager.shared
            var failure: Error?
            do {
                try Task.checkCancellation()
                switch action {
                case .download: try await manager.install(localeIdentifier: model.localeIdentifier)
                case .release: try await manager.release(localeIdentifier: model.localeIdentifier)
                case .use:
                    try await manager.verifyInstalledModel(localeIdentifier: model.localeIdentifier)
                    try Task.checkCancellation()
                    try await MainActor.run {
                        try Task.checkCancellation()
                        guard configuration == ExteraSpeechSettings.shared.configuration else { throw CancellationError() }
                        ExteraSpeechSettings.shared.selectManagedOfflineModel(localeIdentifier: model.localeIdentifier)
                    }
                }
            } catch { failure = error }
            let models = await manager.catalogue()
            let wasCancelled = Task.isCancelled || failure is CancellationError
            await MainActor.run { [weak self] in
                guard let self else { return }
                if wasCancelled {
                    self.message = self.text("Request cancelled. Refresh to check Apple's current asset state.", "Запрос отменён. Обновите список для проверки состояния ресурсов Apple.")
                } else if let failure {
                    self.message = self.errorText(failure)
                } else {
                    switch action {
                    case .download: self.message = self.text("Model installed and retained. Choose Use Model Offline to enable it.", "Модель установлена и сохранена. Выберите «Использовать offline», чтобы включить её.")
                    case .use: self.message = self.text("Apple offline model selected.", "Выбрана offline-модель Apple.")
                    case .release: self.message = self.text("App reservation released. iOS controls deletion of shared files.", "Резервирование приложения снято. Удаление общих файлов контролирует iOS.")
                    }
                }
                self.models = models
                self.loaded = !wasCancelled
                self.operation = nil
                self.refresh.set(true)
                if wasCancelled { self.reload() }
            }
        }
        self.refresh.set(true)
    }

    private func errorText(_ error: Error) -> String {
        switch error as? ExteraSpeechModelError {
        case .busy?: return self.text("A model is in use or another model operation is active. Finish recognition and retry.", "Модель используется или выполняется другая операция. Завершите распознавание и повторите.")
        case .notInstalled?: return self.text("This model is no longer installed or retained. Download it explicitly first.", "Модель больше не установлена или не сохранена. Сначала скачайте её вручную.")
        case .unsupportedLocale?, .unavailable?: return self.text("This Apple model is unavailable on this device.", "Эта модель Apple недоступна на устройстве.")
        case .releaseFailed?: return self.text("Apple still reports this app's reservation. Refresh and retry Release.", "Apple всё ещё сообщает о резервировании. Обновите список и повторите освобождение.")
        default: return self.text("Apple could not complete the request. Check connectivity, free space and the device's model limit, then refresh or retry. No recognition fallback was enabled.", "Apple не удалось завершить запрос. Проверьте сеть, свободное место и лимит моделей устройства, затем обновите список или повторите. Резервный движок распознавания не включался.")
        }
    }
}
