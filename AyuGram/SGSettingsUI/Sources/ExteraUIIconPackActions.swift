import AccountContext
import Display
import SGSimpleSettings
import SGStrings
import TelegramPresentationData
import UIKit
import UniformTypeIdentifiers

func exteraUIIconText(_ context: AccountContext, _ key: String, _ english: String, _ russian: String) -> String {
    let language = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
    let fullKey = "Extera.UIIcons." + key
    let value = i18n(fullKey, language)
    return value.isEmpty || value == fullKey ? (language.hasPrefix("ru") ? russian : english) : value
}

/// Owns document-picker lifetime, security scope and a serial work queue for bounded IO/rendering.
final class ExteraUIIconPackActions: NSObject, UIDocumentPickerDelegate {
    weak var owner: ViewController?
    let context: AccountContext
    private let queue = DispatchQueue(label: "ExteraUIIconPackActions", qos: .userInitiated)
    private var busy = false
    private var replaceResource: (String, String)?
    private var exports: [URL] = []

    init(context: AccountContext, owner: ViewController) { self.context = context; self.owner = owner }
    deinit { for url in self.exports { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
    func text(_ key: String, _ en: String, _ ru: String) -> String { return exteraUIIconText(self.context, key, en, ru) }

    func run<T>(_ work: @escaping () throws -> T, done: @escaping (T) -> Void) {
        guard !self.busy else { return }
        self.busy = true
        self.owner?.view.isUserInteractionEnabled = false
        let indicator = UIActivityIndicatorView(style: .medium)
        if let view = self.owner?.view { indicator.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY); indicator.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]; view.addSubview(indicator); indicator.startAnimating() }
        self.queue.async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.busy = false; indicator.removeFromSuperview(); self.owner?.view.isUserInteractionEnabled = true
                switch result {
                case let .success(value): done(value)
                case let .failure(error): self.error(error)
                }
            }
        }
    }
    func error(_ error: Error) {
        let message: String
        if let error = error as? ExteraUIIconError {
            switch error {
            case .invalidArchive: message = text("ErrorArchive", "The file is not a supported ZIP icon pack.", "Файл не является поддерживаемым ZIP-набором иконок.")
            case .limitExceeded: message = text("ErrorLimit", "The icon pack exceeds its file, size or complexity limit.", "Превышено ограничение на размер, число файлов или сложность иконок.")
            case .invalidMetadata: message = text("ErrorMetadata", "The icon pack metadata is invalid.", "Некорректные сведения о наборе иконок.")
            case .unsafePath: message = text("ErrorPath", "The icon pack contains an unsafe or conflicting file path.", "В наборе есть недопустимые или конфликтующие пути файлов.")
            case .unsupportedImage: message = text("ErrorImage", "An icon uses an unsupported image or SVG feature.", "Изображение или возможности SVG не поддерживаются.")
            case .corruptFile: message = text("ErrorChecksum", "An icon pack file failed its integrity check.", "Файл набора не прошёл проверку целостности.")
            case .storage: message = text("ErrorStorage", "The icon pack could not be saved.", "Не удалось сохранить набор иконок.")
            }
        } else { message = error.localizedDescription }
        let alert = UIAlertController(title: self.text("Error", "Could not open icon pack", "Не удалось открыть набор"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("OK", "OK", "ОК"), style: .default))
        self.owner?.present(alert, animated: true)
    }
    func chooseArchive() { self.replaceResource = nil; self.choose(types: ["public.data", "public.zip-archive"]) }
    func chooseImage(pack: String, resource: String) {
        self.replaceResource = (pack, resource)
        self.choose(types: ["public.image", "public.svg-image", "public.xml", "public.data"])
    }
    private func choose(types: [String]) {
        guard !self.busy else { return }
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: types.compactMap { UTType($0) }, asCopy: false)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: types, in: .open)
        }
        picker.delegate = self; picker.allowsMultipleSelection = false
        self.owner?.present(picker, animated: true)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { self.replaceResource = nil }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let replacement = self.replaceResource; self.replaceResource = nil
        self.run({
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var fileError: Error?, coordinatorError: NSError?, result: Data?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
                do { result = try ExteraUIIconArchive.readFile(readable, limit: replacement == nil ? ExteraUIIconArchive.maxArchiveBytes : ExteraUIIconArchive.maxFileBytes) }
                catch { fileError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let fileError { throw fileError }
            guard var bytes = result else { throw ExteraUIIconError.storage }
            if let (id, resource) = replacement {
                var ext = url.pathExtension.lowercased()
                if ext == "xml" { bytes = try ExteraUIIconVector.svgData(bytes); ext = "svg" }
                _ = try ExteraUIIconRendering.image(data: bytes, path: "icon." + ext)
                try ExteraUIIconPackStore.shared.edit(id, resource: resource, image: bytes, fileExtension: ext)
                return nil as ExteraUIIconPackImport?
            }
            let preview = try ExteraUIIconPackImport.validate(bytes)
            try ExteraUIIconRendering.validate(preview)
            return preview
        }, done: { [weak self] preview in
            guard let self, let preview else { return }
            self.owner?.push(ExteraUIIconPackEditorController(context: self.context, preview: preview))
        })
    }
    func details(_ pack: ExteraCustomUIIconPack? = nil) {
        let alert = UIAlertController(title: self.text("PackDetails", "Pack details", "Сведения о наборе"), message: nil, preferredStyle: .alert)
        for (placeholder, value) in [(self.text("Name", "Name", "Название"), pack?.name), (self.text("Author", "Author", "Автор"), pack?.author), (self.text("Version", "Version", "Версия"), pack?.version ?? "1.0")] {
            alert.addTextField { field in field.placeholder = placeholder; field.text = value; field.autocorrectionType = .no }
        }
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Cancel", "Отмена"), style: .cancel))
        let save = UIAlertAction(title: self.text("Save", "Save", "Сохранить"), style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            let name = fields[0].text ?? "", author = fields[1].text ?? "", version = fields[2].text ?? "1.0"
            self.run({ () -> ExteraCustomUIIconPack? in
                if let pack { try ExteraUIIconPackStore.shared.edit(pack.id, name: name, author: author, version: version); return nil }
                return try ExteraUIIconPackStore.shared.create(name: name, author: author, version: version)
            }, done: { [weak self] created in
                guard let self, let created else { return }
                self.owner?.push(ExteraUIIconPackEditorController(context: self.context, pack: created))
            })
        }
        alert.addAction(save)
        self.owner?.present(alert, animated: true)
    }
    func export(_ pack: ExteraCustomUIIconPack) {
        self.run({
            let bytes = try ExteraUIIconPackStore.shared.export(pack)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UIIconExport-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safe = pack.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
            let url = directory.appendingPathComponent(String(safe.prefix(80)) + ".icons")
            try bytes.write(to: url, options: .atomic)
            return url
        }, done: { [weak self] url in
            guard let self, let owner = self.owner else { return }
            self.exports.append(url)
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = owner.view
            share.popoverPresentationController?.sourceRect = CGRect(x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
            owner.present(share, animated: true)
        })
    }
}
