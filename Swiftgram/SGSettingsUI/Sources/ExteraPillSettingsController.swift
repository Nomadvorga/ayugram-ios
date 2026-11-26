import AccountContext
import ChatListUI
import Display
import Foundation
import SGItemListUI
import SGSimpleSettings
import UIKit
import UniformTypeIdentifiers

/// Central settings entry: push this controller with the existing Display NavigationController.
public func exteraPillSettingsController(context: AccountContext) -> ViewController {
    let transfers = ExteraPillTransfers(context: context)
    return exteraPillDashboardController(context: context, edit: { controller, spec in
        let editor = ExteraPillEditorController(context: context, spec: spec ?? ExteraPillSpec())
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        navigation.isModalInPresentation = true
        controller.present(navigation, animated: true)
    }, transfer: { controller in
        transfers.show(from: controller)
    })
}

private final class ExteraPillEditorController: UITableViewController, UITextFieldDelegate {
    private let context: AccountContext
    private var spec: ExteraPillSpec
    private let fields: [UITextField] = (0 ..< 7).map { _ in UITextField() }
    private let format = UISegmentedControl(items: ["", "", "", ""])
    private let enabled: SGExteraToggleControl
    private var names: [String] {
        return [self.text("Label", "Название"), self.text("HTTP URL", "HTTP URL"), self.text("JSON Path", "Путь JSON"), self.text("Refresh (seconds)", "Обновление (секунды)"), self.text("Decimal places", "Знаков после запятой"), self.text("Prefix", "Префикс"), self.text("Suffix", "Суффикс")]
    }

    init(context: AccountContext, spec: ExteraPillSpec) {
        self.context = context
        self.spec = spec
        let theme = context.sharedContext.currentPresentationData.with { $0 }.theme
        self.enabled = SGExteraToggleControl(value: spec.enabled, theme: theme, style: exteraSettingsAppearance().controlStyle)
        super.init(style: .insetGrouped)
        self.title = spec.label.isEmpty ? self.text("New HTTP Pill", "Новая HTTP-плашка") : self.text("Edit HTTP Pill", "Настройка HTTP-плашки")
    }

    required init?(coder: NSCoder) { preconditionFailure() }

    private var languageCode: String { self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode }

    private func text(_ english: String, _ russian: String) -> String {
        return exteraPillText(self.languageCode, english, russian)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.text("Cancel", "Отмена"), style: .plain, target: self, action: #selector(self.cancelPressed))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.text("Save", "Сохранить"), style: .done, target: self, action: #selector(self.savePressed))
        self.tableView.keyboardDismissMode = .interactive
        let values = [self.spec.label, self.spec.url, self.spec.jsonPath, String(self.spec.refresh), String(self.spec.decimals), self.spec.prefix, self.spec.suffix]
        let optional = self.text("Optional", "Необязательно")
        let placeholders = [self.text("Server status", "Статус сервера"), "https://example.com/status.json", "data.items[0].value", self.text("300 (0 = manual)", "300 (0 = вручную)"), "2", optional, optional]
        for index in values.indices {
            let field = self.fields[index]
            field.text = values[index]
            field.placeholder = placeholders[index]
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
            field.delegate = self
            field.tag = index
            field.accessibilityLabel = self.names[index]
            field.returnKeyType = index == values.count - 1 ? .done : .next
        }
        self.fields[1].keyboardType = .URL
        self.fields[3].keyboardType = .numberPad
        self.fields[4].keyboardType = .numberPad
        let formats = [self.text("Text", "Текст"), self.text("Number", "Число"), "%", self.text("Bytes", "Байты")]
        for index in formats.indices { self.format.setTitle(formats[index], forSegmentAt: index) }
        self.format.selectedSegmentIndex = ExteraPillSpec.Format.allCases.firstIndex(of: self.spec.format) ?? 0
        self.format.accessibilityLabel = self.text("Value format", "Формат значения")
        self.enabled.setOn(self.spec.enabled, animated: false)
        self.enabled.accessibilityLabel = self.text("Enable pill", "Включить плашку")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { return 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return section == 0 ? 1 : 4 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return [self.text("Display", "Отображение"), self.text("Request", "Запрос"), self.text("Formatting", "Форматирование")][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return self.text("Enabled pills appear in the live dashboard.", "Включённые плашки отображаются на панели данных.")
        case 1: return self.text("GET requests return JSON. Empty path selects the root; use data.value, items[0], items[-1], [\"key.with.dots\"], or items.length. Refresh: 0 for manual, or 60–86400 seconds. HTTP availability follows iOS transport policy.", "GET-запрос должен возвращать JSON. Пустой путь выбирает корневое значение; примеры: data.value, items[0], items[-1], [\"key.with.dots\"], items.length. Интервал: 0 — вручную, либо 60–86400 секунд. Доступность HTTP зависит от сетевой политики iOS.")
        default: return self.text("Select a string, number, or boolean. Percent treats 0.25 as 25%. Decimal places: 0–8. Values are limited to 128 characters. Requests run only while the dashboard is visible.", "Выберите строку, число или логическое значение. Формат процентов отображает 0,25 как 25%. Знаков после запятой: 0–8. Длина значения ограничена 128 символами. Запросы выполняются, пока панель данных открыта.")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 0 {
            cell.textLabel?.text = self.text("Enabled", "Включено")
            cell.accessoryView = self.enabled
        } else if indexPath.section == 2, indexPath.row == 0 {
            self.format.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(self.format)
            NSLayoutConstraint.activate([
                self.format.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                self.format.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                self.format.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                self.format.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
            ])
        } else {
            let index = indexPath.section == 1 ? indexPath.row : indexPath.row + 3
            let label = UILabel()
            label.text = self.names[index]
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            let stack = UIStackView(arrangedSubviews: [label, self.fields[index]])
            stack.axis = .vertical
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
                self.fields[index].heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            ])
        }
        return cell
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField.tag < 6 { self.fields[textField.tag + 1].becomeFirstResponder() }
        else { textField.resignFirstResponder() }
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        guard let range = Range(range, in: current) else { return false }
        let replacement = current.replacingCharacters(in: range, with: string)
        let limits = [32, 2048, 256, 5, 1, 32, 32]
        let length = textField.tag == 1 || textField.tag == 2 ? replacement.utf8.count : replacement.count
        return length <= limits[textField.tag]
    }

    @objc private func cancelPressed() { self.dismiss(animated: true) }

    @objc private func savePressed() {
        self.view.endEditing(true)
        guard let refresh = Int(self.fields[3].text ?? ""), let decimals = Int(self.fields[4].text ?? "") else {
            self.showError(self.text("Enter whole numbers for refresh seconds and decimal places.", "Введите целые числа для интервала обновления и количества знаков после запятой."))
            return
        }
        var spec = self.spec
        spec.label = self.fields[0].text ?? ""
        spec.url = self.fields[1].text ?? ""
        spec.jsonPath = self.fields[2].text ?? ""
        spec.refresh = refresh
        spec.decimals = decimals
        spec.prefix = self.fields[5].text ?? ""
        spec.suffix = self.fields[6].text ?? ""
        spec.format = ExteraPillSpec.Format.allCases[self.format.selectedSegmentIndex]
        spec.enabled = self.enabled.isOn
        do {
            try ExteraPillSettings.shared.upsert(spec)
            self.dismiss(animated: true)
        } catch let error as ExteraPillError { self.showError(exteraPillErrorDescription(error, languageCode: self.languageCode)) }
        catch { self.showError(self.text("The pill could not be saved.", "Не удалось сохранить плашку.")) }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: self.text("HTTP Pill", "HTTP-плашка"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("OK", "ОК"), style: .default))
        self.present(alert, animated: true)
    }
}

private final class ExteraPillExportFile {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("extera-pills-\(UUID().uuidString)", isDirectory: true)
    deinit { try? FileManager.default.removeItem(at: self.directory) }
}

private final class ExteraPillTransfers: NSObject, UIDocumentPickerDelegate {
    private let context: AccountContext
    private weak var controller: ViewController?
    private var busy = false

    init(context: AccountContext) {
        self.context = context
        super.init()
    }

    private func text(_ english: String, _ russian: String) -> String {
        let language = self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        return exteraPillText(language, english, russian)
    }

    func show(from controller: ViewController) {
        guard !self.busy else { return }
        self.controller = controller
        let alert = UIAlertController(title: self.text("Pill Files", "Файлы плашек"), message: self.text("Import or share the native iOS HTTP pill configuration.", "Импорт и отправка настроек HTTP-плашек для iOS."), preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: self.text("Import JSON File", "Импорт файла JSON"), style: .default, handler: { [weak self] _ in self?.importFile() }))
        alert.addAction(UIAlertAction(title: self.text("Export JSON File", "Экспорт файла JSON"), style: .default, handler: { [weak self] _ in self?.exportFile() }))
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        self.anchor(alert, controller: controller)
        controller.present(alert, animated: true)
    }

    private func anchor(_ controller: UIViewController, controller source: UIViewController) {
        if let popover = controller.popoverPresentationController {
            popover.sourceView = source.view
            popover.sourceRect = CGRect(x: source.view.bounds.midX, y: source.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
    }

    private func exportFile() {
        guard let controller = self.controller else { return }
        let temporary = ExteraPillExportFile()
        do {
            let data = try ExteraPillSettings.shared.exportData()
            try FileManager.default.createDirectory(at: temporary.directory, withIntermediateDirectories: true)
            let url = temporary.directory.appendingPathComponent("exteragram-ios-pills.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            self.anchor(share, controller: controller)
            self.busy = true
            share.completionWithItemsHandler = { [weak self] _, _, _, error in
                _ = temporary // Keep the file alive until sharing finishes or the controller deallocates.
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    if error != nil { self.showError(self.text("The pill file could not be shared.", "Не удалось отправить файл плашек.")) }
                }
            }
            controller.present(share, animated: true)
        } catch { self.showError(self.text("The pill file could not be exported.", "Не удалось экспортировать файл плашек.")) }
    }

    private func importFile() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: false) }
        else { picker = UIDocumentPickerViewController(documentTypes: ["public.json"], in: .open) }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        self.busy = true
        self.controller?.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { self.busy = false }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, urls.count == 1 else { self.busy = false; return }
        controller.dismiss(animated: true, completion: { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ExteraPillSettings.decode(Self.read(url)) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    switch result {
                    case let .success(pills): self.confirm(pills)
                    case .failure: self.showError(self.text("Choose a native iOS pills JSON file up to 64 KB. Android .pill files use a different format.", "Выберите файл JSON с плашками для iOS размером до 64 КБ. Файлы Android .pill используют другой формат."))
                    }
                }
            }
        })
    }

    private static func read(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ExteraPillError.invalidFile)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: { url in
            result = Result {
                guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                      let stream = InputStream(url: url) else { throw ExteraPillError.invalidFile }
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while data.count <= ExteraPillSettings.maximumFileSize {
                    let count = stream.read(&buffer, maxLength: min(buffer.count, ExteraPillSettings.maximumFileSize + 1 - data.count))
                    guard count >= 0 else { throw ExteraPillError.invalidFile }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                guard data.count <= ExteraPillSettings.maximumFileSize else { throw ExteraPillError.invalidFile }
                return data
            }
        })
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func confirm(_ pills: [ExteraPillSpec]) {
        guard let controller = self.controller, controller.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: self.text("Import Pills (\(pills.count))?", "Импорт плашек (\(pills.count))?"), message: self.text("Replace the current pill list? Imported pills will start disabled so you can review their URLs before making requests.", "Заменить текущий список плашек? Импортированные плашки будут отключены, чтобы вы могли проверить URL перед выполнением запросов."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Replace", "Заменить"), style: .destructive, handler: { [weak self] _ in
            do {
                try ExteraPillSettings.shared.replace(pills.map { pill in var pill = pill; pill.enabled = false; return pill })
            } catch {
                guard let self else { return }
                self.showError(self.text("The pill list could not be imported.", "Не удалось импортировать список плашек."))
            }
        }))
        controller.present(alert, animated: true)
    }

    private func showError(_ message: String) {
        guard let controller = self.controller, controller.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: self.text("HTTP Pills", "HTTP-плашки"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("OK", "ОК"), style: .default))
        controller.present(alert, animated: true)
    }
}
