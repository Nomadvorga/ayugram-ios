import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramPresentationData
import UIKit
import VoskSpeech

private enum VoskSection: Int32, SGItemListSection { case selection, operation, models, info }
private typealias VoskEntry = SGItemListUIEntry<VoskSection, Int, Int, Int, Int, Int>
private enum VoskRow {
    case action(VoskSection, String, () -> Void)
    case notice(VoskSection, String)
}

/// Real Vosk catalogue: all 24 Android models, app-owned downloads and deletion.
public func sgVoskRecognitionController(context: AccountContext) -> ViewController {
    let page = VoskRecognitionPage(context: context)
    let state = combineLatest(context.sharedContext.presentationData, page.refresh.get())
    |> deliverOnMainQueue
    |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rows = page.rows()
        let entries: [VoskEntry] = rows.enumerated().map { index, row in
            switch row {
            case let .action(section, title, _): return .action(id: index, section: section, actionType: index, text: title, kind: .generic)
            case let .notice(section, title): return .notice(id: index, section: section, text: title)
            }
        }
        let arguments = SGItemListArguments<Int, Int, Int, Int, Int>(context: context, visualStyle: .extera, action: { index in
            if rows.indices.contains(index), case let .action(_, _, action) = rows[index] { action() }
        })
        let controller = ItemListControllerState(presentationData: ItemListPresentationData(data), title: .text("Vosk"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back))
        return (controller, (ItemListNodeState(presentationData: ItemListPresentationData(data), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    let controller = ItemListController(context: context, state: state)
    page.controller = controller
    controller.didAppear = { [weak page] _ in page?.reload() }
    return controller
}

private final class VoskRecognitionPage {
    let context: AccountContext
    weak var controller: ViewController?
    let refresh = ValuePromise(true, ignoreRepeated: false)
    private var operation: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var models = VoskModelStore.shared.catalogue()
    private var progress: Int?
    private var title = ""
    private var message: String?

    init(context: AccountContext) {
        self.context = context
        self.observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    deinit {
        self.operation?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func text(_ key: String) -> String {
        let language = self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        return i18n("Extera.Vosk." + key, language)
    }

    private func name(_ model: VoskModelDescriptor) -> String {
        let locale = Locale(identifier: self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
        return locale.localizedString(forLanguageCode: model.language) ?? model.language
    }

    func reload() {
        self.models = VoskModelStore.shared.catalogue()
        self.refresh.set(true)
    }

    func rows() -> [VoskRow] {
        let config = ExteraVoskSettings.shared.configuration
        var rows: [VoskRow] = [
            .action(.selection, (config.isSelected && (!config.isEnabled || config.language == "none") ? "✓ " : "") + self.text("None"), { [weak self] in self?.select("none") }),
            .action(.selection, (config.isSelected && config.isEnabled && config.language == "auto" ? "✓ " : "") + self.text("Automatic"), { [weak self] in self?.select("auto") })
        ]
        if self.operation != nil {
            rows.append(.notice(.operation, self.title + (self.progress.map { " · \($0)%" } ?? "")))
            rows.append(.action(.operation, self.text("Cancel"), { [weak self] in self?.operation?.cancel() }))
        }
        if let message { rows.append(.notice(.operation, message)) }
        for status in self.models {
            let selected = config.isSelected && config.isEnabled && config.language == status.model.language
            let size = ByteCountFormatter.string(fromByteCount: status.model.archiveBytes, countStyle: .file)
            let state = status.isInstalled ? self.text("Installed") : size
            rows.append(.action(.models, (selected ? "✓ " : "") + self.name(status.model) + " · " + state, { [weak self] in self?.open(status) }))
        }
        rows.append(.notice(.info, self.text("Info")))
        rows.append(.notice(.info, "Vosk · Alpha Cephei · Apache-2.0. " + self.text("Licenses")))
        return rows
    }

    private func select(_ language: String) {
        guard self.operation == nil else { return }
        ExteraVoskSettings.shared.select(language: language)
    }

    private func open(_ status: VoskModelStatus) {
        guard self.operation == nil else { return }
        let alert = UIAlertController(title: self.name(status.model), message: status.model.name + "\n" + status.model.license, preferredStyle: .alert)
        if status.isInstalled {
            alert.addAction(UIAlertAction(title: self.text("UseModel"), style: .default, handler: { [weak self] _ in self?.run(status.model, action: .use) }))
            alert.addAction(UIAlertAction(title: self.text("DeleteModel"), style: .destructive, handler: { [weak self] _ in self?.confirmDelete(status.model) }))
        } else {
            alert.addAction(UIAlertAction(title: self.text("DownloadModel"), style: .default, handler: { [weak self] _ in self?.run(status.model, action: .download) }))
        }
        alert.addAction(UIAlertAction(title: self.text("Cancel"), style: .cancel))
        self.controller?.present(alert, animated: true)
    }

    private func confirmDelete(_ model: VoskModelDescriptor) {
        let alert = UIAlertController(title: self.text("DeleteModel"), message: self.name(model) + "\n" + self.text("DeleteConfirmation"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("Delete"), style: .destructive, handler: { [weak self] _ in self?.run(model, action: .delete) }))
        alert.addAction(UIAlertAction(title: self.text("Cancel"), style: .cancel))
        self.controller?.present(alert, animated: true)
    }

    private enum Action { case download, use, delete }

    private func run(_ model: VoskModelDescriptor, action: Action) {
        guard self.operation == nil else { return }
        self.message = nil
        self.progress = nil
        self.title = self.name(model) + " · " + self.text("Working")
        self.operation = Task { [weak self] in
            var failure: Error?
            do {
                try Task.checkCancellation()
                switch action {
                case .download:
                    try await VoskModelStore.shared.install(language: model.language, progress: { [weak self] value in
                        DispatchQueue.main.async { [weak self] in
                            let percent = Int(value * 100)
                            if self?.progress != percent { self?.progress = percent; self?.refresh.set(true) }
                        }
                    })
                case .use: try await VoskModelStore.shared.use(language: model.language)
                case .delete: try await VoskModelStore.shared.delete(language: model.language)
                }
            } catch { failure = error }
            // Successful deletion has already committed and updated preferences,
            // even if Cancel arrives after unlink began.
            let cancelled = failure != nil && (Task.isCancelled || (failure as? VoskSpeechError) == .cancelled)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.operation = nil
                self.progress = nil
                if cancelled { self.message = self.text("Cancelled") }
                else if let failure { self.message = self.error(failure) }
                else {
                    switch action {
                    case .download: self.message = self.text("DownloadComplete")
                    case .use: self.message = self.text("UseComplete")
                    case .delete: self.message = self.text("DeleteComplete")
                    }
                }
                self.reload()
            }
        }
        self.refresh.set(true)
    }

    private func error(_ error: Error) -> String {
        switch error as? VoskSpeechError {
        case .busy: return self.text("ErrorBusy")
        case .integrityFailed, .unsafeArchive: return self.text("ErrorIntegrity")
        case .notInstalled: return self.text("ErrorNotInstalled")
        case .invalidModel: return self.text("ErrorInvalidModel")
        default: return self.text("ErrorOperation")
        }
    }
}
