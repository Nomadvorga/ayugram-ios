import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

private enum ExteraAISection: Int32, SGItemListSection { case main, options, details, actions }
private typealias ExteraAIEntry = SGItemListUIEntry<ExteraAISection, Int, Int, Int, Int, Int>

private enum ExteraAIRow {
    case action(ExteraAISection, String, ItemListActionKind, () -> Void)
    case toggle(ExteraAISection, String, Bool, (Bool) -> Void)
    case notice(ExteraAISection, String)
    case header(ExteraAISection, String)
}

/// The settings integration entry point. Push it with the existing native NavigationController.
public func exteraAISettingsController(context: AccountContext) -> ViewController {
    return ExteraAIList.make(context: context, title: "AI", build: { page in
        let config = ExteraAISettings.shared.configuration
        let selected = config.selectedService?.name ?? page.text("Not configured", "Не настроен")
        return [
            .action(.main, page.text("AI Chat", "Чат с ИИ"), .generic, { page.push(exteraAIChatController(context: context)) }),
            .action(.main, page.text("Services", "Сервисы") + ": " + selected, .generic, { page.openServices() }),
            .action(.main, page.text("Roles", "Роли") + ": " + (config.selectedRole?.name ?? page.text("None", "Нет")), .generic, { page.openRoles() }),
            .action(.main, page.text("Message History", "История сообщений") + " (\(ExteraAISettings.shared.history(accountId: page.accountId).count))", .generic, { page.openHistory() }),
            .action(.main, page.text("Improve Text", "Улучшить текст"), .generic, { page.push(exteraAITextProcessingController(context: context, text: "", action: .improve)) }),
            .action(.main, page.text("Summarize Text", "Сократить текст"), .generic, { page.push(exteraAITextProcessingController(context: context, text: "", action: .summarize)) }),
            .notice(.main, page.text("Messages are sent to your selected provider when you press Send. API keys are stored in this device’s Keychain. Chat history is stored locally and separately for each Telegram account.", "Сообщения отправляются выбранному провайдеру по нажатию «Отправить». Ключи API хранятся в Связке ключей устройства, история чата — локально и отдельно для каждого аккаунта Telegram.")),
            .toggle(.options, page.text("Save Chat History", "Сохранять историю чата"), config.saveHistory, { value in page.change { $0.saveHistory = value } }),
            .toggle(.options, page.text("Stream Responses", "Потоковые ответы"), config.responseStreaming, { value in page.change { $0.responseStreaming = value } }),
            .toggle(.options, page.text("Use in Telegram Text Editor", "Использовать в редакторе Telegram"), config.useForTextProcessing, { value in page.change { $0.useForTextProcessing = value } }),
            .notice(.options, page.text("When enabled, opening proofreading or translation, or applying a style/prompt, sends the editor text to your selected AI service. These requests never use or save chat history. Changed output is plain text; rich documents are rejected. A separately selected translation provider takes precedence for translation.", "При включении проверка, перевод текста и применение стиля или инструкции отправляют текст редактора выбранному сервису ИИ. Эти запросы не используют и не сохраняют историю чата. Изменённый результат — обычный текст; документы с расширенным форматированием не поддерживаются. Отдельно выбранный провайдер перевода имеет приоритет.")),
            .action(.options, page.text("Temperature", "Температура") + ": " + String(format: "%.1f", config.temperature), .generic, {
                page.input(title: page.text("Temperature (0–2)", "Температура (0–2)"), value: String(config.temperature), keyboard: .decimalPad, save: { text in
                    guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, (0.0...2.0).contains(value) else { throw ExteraAIError.configuration(page.text("Enter a number from 0 to 2.", "Введите число от 0 до 2.")) }
                    try ExteraAISettings.shared.update { $0.temperature = value }
                })
            }),
            .notice(.options, page.text("Higher temperature makes answers more varied. Some models use their own temperature. Turning history off stops sending or saving earlier turns; it does not delete existing history.", "Чем выше температура, тем разнообразнее ответы. Некоторые модели используют собственную температуру. При отключённой истории предыдущие сообщения не отправляются и новые не сохраняются; старая история остаётся."))
        ]
    })
}

private final class ExteraAIServiceDraft {
    var service: ExteraAIService
    var key: String
    var existing: Bool

    init(service: ExteraAIService, key: String, existing: Bool) {
        self.service = service
        self.key = key
        self.existing = existing
    }
}

private final class ExteraAIRoleDraft {
    var role: ExteraAIRole
    var existing: Bool
    init(role: ExteraAIRole, existing: Bool) { self.role = role; self.existing = existing }
}

private final class ExteraAIList {
    let context: AccountContext
    let accountId: String
    weak var controller: ViewController?
    private let refresh = ValuePromise(true, ignoreRepeated: false)
    private var observer: NSObjectProtocol?
    private var modelsRequest: ExteraAIModelRequest?
    private var testRequest: ExteraAIRequest?
    private var busy = false

    init(context: AccountContext) {
        self.context = context
        self.accountId = String(context.account.id.int64)
        self.observer = NotificationCenter.default.addObserver(forName: ExteraAISettings.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in self?.refresh.set(true) })
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.modelsRequest?.cancel()
        self.testRequest?.cancel()
    }

    static func make(context: AccountContext, title: String, build: @escaping (ExteraAIList) -> [ExteraAIRow]) -> ViewController {
        let page = ExteraAIList(context: context)
        let signal = combineLatest(context.sharedContext.presentationData, page.refresh.get())
        |> deliverOnMainQueue
        |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let rows = build(page)
            let entries: [ExteraAIEntry] = rows.enumerated().map { index, row in
                switch row {
                case let .action(section, text, kind, _): return .action(id: index, section: section, actionType: index, text: text, kind: kind)
                case let .toggle(section, text, value, _): return .toggle(id: index, section: section, settingName: index, value: value, text: text, enabled: true)
                case let .notice(section, text): return .notice(id: index, section: section, text: text)
                case let .header(section, text): return .header(id: index, section: section, text: text, badge: nil)
                }
            }
            let arguments = SGItemListArguments<Int, Int, Int, Int, Int>(context: context, setBoolValue: { index, value in
                if rows.indices.contains(index), case let .toggle(_, _, _, update) = rows[index] { update(value) }
            }, action: { index in
                if rows.indices.contains(index), case let .action(_, _, _, action) = rows[index] { action() }
            })
            let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
            return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments))
        }
        let controller = ItemListController(context: context, state: signal)
        page.controller = controller
        return controller
    }

    func text(_ english: String, _ russian: String) -> String {
        return self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode.hasPrefix("ru") ? russian : english
    }

    func push(_ controller: ViewController) { (self.controller?.navigationController as? NavigationController)?.pushViewController(controller) }

    private func pop() { let _ = (self.controller?.navigationController as? NavigationController)?.popViewController(animated: true) }

    func change(_ body: (inout ExteraAIConfiguration) -> Void) {
        do { try ExteraAISettings.shared.update(body) } catch { self.showError(error) }
    }

    private func showError(_ error: Error) { self.message(title: self.text("AI Error", "Ошибка ИИ"), message: error.localizedDescription) }

    private func message(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("OK", "ОК"), style: .default))
        self.controller?.present(alert, animated: true)
    }

    private func confirm(_ message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: self.text("Confirm", "Подтверждение"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Delete", "Удалить"), style: .destructive, handler: { _ in action() }))
        self.controller?.present(alert, animated: true)
    }

    func input(title: String, value: String, secure: Bool = false, keyboard: UIKeyboardType = .default, save: @escaping (String) throws -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField(configurationHandler: { field in
            field.text = value
            field.isSecureTextEntry = secure
            field.keyboardType = keyboard
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.accessibilityLabel = title
        })
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Done", "Готово"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self else { return }
            do { try save(alert?.textFields?.first?.text ?? ""); self.refresh.set(true) } catch {
                DispatchQueue.main.async { [weak self] in self?.showError(error) }
            }
        }))
        self.controller?.present(alert, animated: true)
    }

    private func choose(title: String, options: [(String, () -> Void)]) {
        // A native list scales to long model catalogs and avoids an unscrollable alert.
        self.push(Self.make(context: self.context, title: title, build: { page in
            options.map { title, action in .action(.main, title, .generic, { page.pop(); action() }) }
        }))
    }

    func openServices() {
        self.push(Self.make(context: self.context, title: self.text("Services", "Сервисы"), build: { page in
            let config = ExteraAISettings.shared.configuration
            var rows: [ExteraAIRow] = config.services.map { service in
                .action(.main, (config.selectedService?.id == service.id ? "✓ " : "") + service.name + " · " + service.model, .generic, {
                    do {
                        let key = try ExteraAISettings.shared.apiKey(serviceId: service.id)
                        page.openService(ExteraAIServiceDraft(service: service, key: key, existing: true))
                    } catch { page.showError(error) }
                })
            }
            rows.append(.action(.options, page.text("Add Service", "Добавить сервис"), .generic, {
                page.choose(title: page.text("Provider", "Провайдер"), options: ExteraAIService.presets.map { service in
                    (service.name, { [weak page = page] in page?.openService(ExteraAIServiceDraft(service: service, key: "", existing: false)) })
                })
            }))
            rows.append(.notice(.options, page.text("Choose a service to edit its endpoint, model and API key or make it active. Custom services must support OpenAI Chat Completions or Responses. Empty API keys are permitted for servers that do not require authentication.", "Выберите сервис, чтобы изменить адрес, модель, ключ API или сделать его активным. Пользовательские сервисы должны поддерживать OpenAI Chat Completions или Responses. Для серверов без авторизации ключ может быть пустым.")))
            return rows
        }))
    }

    private func openService(_ draft: ExteraAIServiceDraft) {
        self.push(Self.make(context: self.context, title: self.text("AI Service", "Сервис ИИ"), build: { page in
            var rows: [ExteraAIRow] = [
                .action(.main, page.text("Name", "Название") + ": " + draft.service.name, .generic, { page.input(title: page.text("Name", "Название"), value: draft.service.name, save: { draft.service.name = String($0.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines) }) }),
                .action(.main, "URL: " + draft.service.endpoint, .generic, { page.input(title: page.text("Service URL", "Адрес сервиса"), value: draft.service.endpoint, keyboard: .URL, save: { value in
                    var service = draft.service; service.endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = try ExteraAIClient.endpoint(for: service)
                    draft.service = service
                }) }),
                .action(.main, page.text("Model", "Модель") + ": " + draft.service.model, .generic, { page.input(title: page.text("Model ID", "ID модели"), value: draft.service.model, save: { draft.service.model = String($0.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines) }) }),
                .action(.main, page.text("API Key", "Ключ API") + ": " + (draft.key.isEmpty ? page.text("Not set", "Не задан") : "••••••••"), .generic, { page.input(title: page.text("API Key", "Ключ API"), value: draft.key, secure: true, save: { value in
                    guard !value.contains("\n"), !value.contains("\r"), value.utf8.count <= 16384 else { throw ExteraAIError.configuration(page.text("Invalid API key.", "Неверный ключ API.")) }
                    draft.key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }) }),
                .toggle(.main, page.text("Allow Reasoning", "Разрешить рассуждения"), draft.service.reasoningEnabled, { draft.service.reasoningEnabled = $0; page.refresh.set(true) }),
                .action(.options, page.text("Fetch Available Models", "Загрузить доступные модели"), .generic, { page.fetchModels(draft) }),
                .action(.options, page.text("Test Service", "Проверить сервис"), .generic, { page.test(draft) }),
                .notice(.options, page.busy ? page.text("Contacting the AI service…", "Подключение к сервису ИИ…") : page.text("You can enter any model ID supported by the provider. Test sends a short request and may use your provider credits. Unsaved edits are discarded when you go back.", "Можно ввести любой ID модели, поддерживаемой провайдером. Проверка отправляет короткий запрос и может расходовать средства провайдера. Несохранённые изменения удаляются при возврате.")),
                .action(.actions, page.text("Save and Use Service", "Сохранить и использовать"), .generic, { page.saveService(draft) })
            ]
            if page.busy { rows.append(.action(.actions, page.text("Cancel Request", "Отменить запрос"), .generic, { page.modelsRequest?.cancel(); page.testRequest?.cancel() })) }
            if draft.existing {
                rows.append(.action(.actions, page.text("Delete Service", "Удалить сервис"), .destructive, {
                    page.confirm(page.text("Delete this service and its API key?", "Удалить сервис и его ключ API?"), action: {
                        do {
                            try ExteraAISettings.shared.setAPIKey("", serviceId: draft.service.id)
                            try ExteraAISettings.shared.update { config in
                                config.services.removeAll { $0.id == draft.service.id }
                                if config.selectedServiceId == draft.service.id { config.selectedServiceId = nil }
                            }
                            page.pop()
                        } catch { page.showError(error) }
                    })
                }))
            }
            return rows
        }))
    }

    private func saveService(_ draft: ExteraAIServiceDraft) {
        do {
            _ = try ExteraAIClient.endpoint(for: draft.service)
            guard !draft.service.name.isEmpty, !draft.service.model.isEmpty else { throw ExteraAIError.configuration(self.text("Enter a name and model ID.", "Введите название и ID модели.")) }
            let oldKey = try ExteraAISettings.shared.apiKey(serviceId: draft.service.id)
            try ExteraAISettings.shared.setAPIKey(draft.key, serviceId: draft.service.id)
            do {
                try ExteraAISettings.shared.update { config in
                    if let index = config.services.firstIndex(where: { $0.id == draft.service.id }) { config.services[index] = draft.service } else { config.services.append(draft.service) }
                    config.selectedServiceId = draft.service.id
                }
            } catch {
                try? ExteraAISettings.shared.setAPIKey(oldKey, serviceId: draft.service.id)
                throw error
            }
            draft.existing = true
            self.pop()
        } catch { self.showError(error) }
    }

    private func fetchModels(_ draft: ExteraAIServiceDraft) {
        guard !self.busy else { return }
        do {
            self.busy = true
            self.refresh.set(true)
            self.modelsRequest = try ExteraAIClient.fetchModels(service: draft.service, apiKey: draft.key, completion: { [weak self] result in
                guard let self else { return }
                self.modelsRequest = nil
                self.busy = false
                self.refresh.set(true)
                switch result {
                case let .success(models):
                    self.choose(title: self.text("Model", "Модель"), options: models.prefix(1000).map { model in
                        (model, { [weak self] in draft.service.model = model; self?.refresh.set(true) })
                    })
                case .failure(.cancelled): break
                case let .failure(error): self.showError(error)
                }
            })
        } catch { self.busy = false; self.refresh.set(true); self.showError(error) }
    }

    private func test(_ draft: ExteraAIServiceDraft) {
        guard !self.busy else { return }
        do {
            self.busy = true
            self.refresh.set(true)
            self.testRequest = try ExteraAIClient.generate(service: draft.service, apiKey: draft.key, role: nil, prompt: "Reply with OK.", stream: false, completion: { [weak self] result in
                guard let self else { return }
                self.testRequest = nil
                self.busy = false
                self.refresh.set(true)
                switch result {
                case let .success(text): self.message(title: self.text("Service Responded", "Ответ сервиса"), message: String(text.prefix(1000)))
                case .failure(.cancelled): break
                case let .failure(error): self.showError(error)
                }
            })
        } catch { self.busy = false; self.refresh.set(true); self.showError(error) }
    }

    func openRoles() {
        self.push(Self.make(context: self.context, title: self.text("Roles", "Роли"), build: { page in
            let config = ExteraAISettings.shared.configuration
            var rows: [ExteraAIRow] = [.action(.main, (config.selectedRole == nil ? "✓ " : "") + page.text("No System Role", "Без системной роли"), .generic, { page.change { $0.selectedRoleId = nil } })]
            rows += config.roles.map { role in
                .action(.main, (config.selectedRoleId == role.id ? "✓ " : "") + role.name, .generic, { page.openRole(ExteraAIRoleDraft(role: role, existing: true)) })
            }
            rows.append(.action(.options, page.text("Add Role", "Добавить роль"), .generic, { page.openRole(ExteraAIRoleDraft(role: .init(name: "", prompt: ""), existing: false)) }))
            rows.append(.notice(.options, page.text("A role is a system instruction sent with your request. Select a role to edit or activate it. AI Chat uses the active role; the editor and summarizer use their own explicit instructions.", "Роль — системная инструкция, которая отправляется вместе с запросом. Выберите роль для редактирования или активации. Чат с ИИ использует активную роль; редактор и суммаризатор — собственные инструкции.")))
            return rows
        }))
    }

    private func openRole(_ draft: ExteraAIRoleDraft) {
        self.push(Self.make(context: self.context, title: self.text("AI Role", "Роль ИИ"), build: { page in
            var rows: [ExteraAIRow] = [
                .action(.main, page.text("Name", "Название") + ": " + draft.role.name, .generic, { page.input(title: page.text("Role Name", "Название роли"), value: draft.role.name, save: { draft.role.name = String($0.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines) }) }),
                .action(.main, page.text("Edit System Prompt", "Изменить системную инструкцию"), .generic, {
                    page.push(exteraAITextEditorController(context: page.context, title: page.text("System Prompt", "Системная инструкция"), text: draft.role.prompt, save: { text in
                        guard text.count <= 32000 else { throw ExteraAIError.configuration(page.text("The prompt must contain no more than 32,000 characters.", "Инструкция должна содержать не более 32 000 символов.")) }
                        draft.role.prompt = text
                        page.refresh.set(true)
                    }))
                }),
                .notice(.main, String(draft.role.prompt.prefix(500))),
                .action(.actions, page.text("Save and Use Role", "Сохранить и использовать"), .generic, {
                    guard !draft.role.name.isEmpty, !draft.role.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { page.showError(ExteraAIError.configuration(page.text("Enter a role name and system prompt.", "Введите название и системную инструкцию."))); return }
                    do {
                        try ExteraAISettings.shared.update { config in
                            if let index = config.roles.firstIndex(where: { $0.id == draft.role.id }) { config.roles[index] = draft.role } else { config.roles.append(draft.role) }
                            config.selectedRoleId = draft.role.id
                        }
                        page.pop()
                    } catch { page.showError(error) }
                })
            ]
            if draft.existing { rows.append(.action(.actions, page.text("Delete Role", "Удалить роль"), .destructive, {
                page.confirm(page.text("Delete this role?", "Удалить эту роль?"), action: {
                    page.change { config in config.roles.removeAll { $0.id == draft.role.id }; if config.selectedRoleId == draft.role.id { config.selectedRoleId = nil } }
                    page.pop()
                })
            })) }
            return rows
        }))
    }

    func openHistory() {
        self.push(Self.make(context: self.context, title: self.text("Message History", "История сообщений"), build: { page in
            let history = ExteraAISettings.shared.history(accountId: page.accountId)
            var rows: [ExteraAIRow] = history.map { message in
                .action(.main, (message.role == .user ? page.text("You: ", "Вы: ") : "AI: ") + String(message.content.replacingOccurrences(of: "\n", with: " ").prefix(100)), .generic, { page.openHistoryMessage(message) })
            }
            rows.append(.notice(.options, page.text("Only this Telegram account’s AI conversation is shown. Up to 64 messages and 64,000 characters are kept. Requests send up to 32 messages and 24,000 characters. Select a message to edit, copy or delete its turn.", "Показана история ИИ только этого аккаунта Telegram: до 64 сообщений и 64 000 символов. В запрос отправляются до 32 сообщений и 24 000 символов. Выберите сообщение для редактирования, копирования или удаления пары вопрос–ответ.")))
            if !history.isEmpty { rows.append(.action(.actions, page.text("Clear History", "Очистить историю"), .destructive, {
                page.confirm(page.text("Delete this account’s AI conversation history?", "Удалить историю ИИ этого аккаунта?"), action: {
                    do { try ExteraAISettings.shared.setHistory([], accountId: page.accountId) } catch { page.showError(error) }
                })
            })) }
            return rows
        }))
    }

    private func openHistoryMessage(_ message: ExteraAIMessage) {
        self.push(Self.make(context: self.context, title: message.role == .user ? self.text("Your Message", "Ваше сообщение") : self.text("AI Response", "Ответ ИИ"), build: { page in
            let current = ExteraAISettings.shared.history(accountId: page.accountId).first { $0.id == message.id }
            guard let current else { return [.notice(.main, page.text("This message was deleted.", "Сообщение удалено."))] }
            return [
                .notice(.main, current.content),
                .action(.options, page.text("Copy", "Копировать"), .generic, { UIPasteboard.general.string = current.content }),
                .action(.options, page.text("Edit", "Изменить"), .generic, {
                    page.push(exteraAITextEditorController(context: page.context, title: page.text("Edit Message", "Изменить сообщение"), text: current.content, save: { text in
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 24000 else { throw ExteraAIError.configuration(page.text("Enter between 1 and 24,000 characters.", "Введите от 1 до 24 000 символов.")) }
                        var history = ExteraAISettings.shared.history(accountId: page.accountId)
                        guard let index = history.firstIndex(where: { $0.id == current.id }) else { throw ExteraAIError.configuration(page.text("This message was deleted.", "Сообщение удалено.")) }
                        history[index].content = text
                        try ExteraAISettings.shared.setHistory(history, accountId: page.accountId)
                    }))
                }),
                .action(.actions, page.text("Delete Turn", "Удалить вопрос и ответ"), .destructive, {
                    page.confirm(page.text("Delete this question and its answer?", "Удалить этот вопрос и ответ?"), action: {
                        var history = ExteraAISettings.shared.history(accountId: page.accountId)
                        if let index = history.firstIndex(where: { $0.id == current.id }) {
                            let start = current.role == .assistant ? max(0, index - 1) : index
                            history.removeSubrange(start..<min(start + 2, history.count))
                            do { try ExteraAISettings.shared.setHistory(history, accountId: page.accountId); page.pop() } catch { page.showError(error) }
                        }
                    })
                })
            ]
        }))
    }
}
