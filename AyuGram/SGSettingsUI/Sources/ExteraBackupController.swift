import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit
import UniformTypeIdentifiers

private enum ExteraBackupSection: Int32, SGItemListSection {
    case files
    case exteraFile
    case reset
}

private enum ExteraBackupAction: Hashable {
    case exportSettings
    case importSettings
    // The ".extera" file exteraGram for Android reads and writes (AyuSettingsBackupUI.swift).
    case exportExteraFile
    case importExteraFile
    case resetSettings
}

private typealias ExteraBackupEntry = SGItemListUIEntry<ExteraBackupSection, Int, Int, Int, Int, ExteraBackupAction>

/// The activity controller retains this through its completion closure. Deallocation also cleans up
/// when UIKit never presents the activity controller or dismisses it without invoking completion.
private final class ExteraBackupTemporaryFile {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("extera-settings-\(UUID().uuidString)", isDirectory: true)

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }

    deinit {
        self.remove()
    }
}

/// Reuse the backup coordinator for the direct Other-card actions.
func exteraOtherBackupAction(context: AccountContext) -> (ViewController, ExteraOtherSettingsModel.SettingsAction) -> Void {
    let actions = ExteraBackupActions(context: context)
    return { controller, action in
        actions.controller = controller
        switch action {
        case .exportSettings: actions.perform(.exportSettings)
        case .resetSettings: actions.perform(.resetSettings)
        }
    }
}

/// Push this controller from the exteraGram Other category. No action changes account or plugin data.
public func exteraBackupController(context: AccountContext) -> ViewController {
    let actions = ExteraBackupActions(context: context)
    let arguments = SGItemListArguments<Int, Int, Int, Int, ExteraBackupAction>(context: context, visualStyle: .extera, action: { action in
        actions.perform(action)
    })
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let entries: [ExteraBackupEntry] = [
            .action(id: 0, section: .files, actionType: .exportSettings, text: i18n("Extera.ExportSettings", lang, "Export Settings"), kind: .generic),
            .action(id: 1, section: .files, actionType: .importSettings, text: i18n("Extera.ImportSettings", lang, "Import Settings"), kind: .generic),
            .notice(id: 2, section: .files, text: i18n("Extera.SettingsBackupInfo", lang, "Back up exteraGram preferences to a JSON file. Accounts, messages, and plugin preferences are excluded.")),
            .action(id: 3, section: .exteraFile, actionType: .exportExteraFile, text: i18n("Extera.ExportSettings", lang) + " (.extera)", kind: .generic),
            .action(id: 4, section: .exteraFile, actionType: .importExteraFile, text: i18n("Extera.ImportSettings", lang) + " (.extera)", kind: .generic),
            .notice(id: 5, section: .exteraFile, text: i18n("Extera.BackupInfo", lang)),
            .action(id: 6, section: .reset, actionType: .resetSettings, text: i18n("Extera.ResetSettings", lang, "Reset Settings"), kind: .destructive),
            .notice(id: 7, section: .reset, text: i18n("Extera.ResetSettingsInfo", lang, "Restore the preferences exposed in exteraGram settings to their defaults. Accounts, messages, and plugin preferences are kept.")),
        ]
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Extera.SettingsBackup", lang, "Settings Backup")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    actions.controller = controller
    return controller
}

private final class ExteraBackupActions: NSObject, UIDocumentPickerDelegate {
    private let context: AccountContext
    weak var controller: ViewController?
    private let operation = MetaDisposable()
    private var busy = false

    init(context: AccountContext) {
        self.context = context
        super.init()
    }

    deinit {
        self.operation.dispose()
    }

    private func text(_ key: String, _ fallback: String) -> String {
        return i18n(key, self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode, fallback)
    }

    func perform(_ action: ExteraBackupAction) {
        guard !self.busy, self.controller?.viewIfLoaded?.window != nil else { return }
        switch action {
        case .exportSettings:
            self.exportSettings()
        case .importSettings:
            self.importSettings()
        case .exportExteraFile:
            if let controller = self.controller {
                ayuExportSettingsBackup(context: self.context, from: controller)
            }
        case .importExteraFile:
            if let controller = self.controller {
                ayuImportSettingsBackup(context: self.context, from: controller, applied: { [weak self] in
                    guard let self else { return }
                    self.showMessage(title: self.text("Extera.SettingsBackup", "Settings Backup"), message: self.text("Extera.SettingsBackupApplied", "Settings updated. Restart the app to apply all changes."))
                })
            }
        case .resetSettings:
            self.confirmReset()
        }
    }

    private func exportSettings() {
        self.busy = true
        let shared = self.context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings])
        self.operation.set((shared |> take(1) |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            guard let controller = self.controller, controller.viewIfLoaded?.window != nil else {
                self.busy = false
                return
            }
            let calls = data.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings
            let experimental = data.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
            let temporaryFile = ExteraBackupTemporaryFile()
            do {
                let iconBackup: Data?
                if ExteraUIIconPackStore.shared.snapshot.all.isEmpty {
                    iconBackup = nil
                } else {
                    iconBackup = try ExteraUIIconPackStore.shared.exportBackup()
                }
                let data = try ExteraSettingsBackup.exportBundle(sharedPreferences: .init(showContactsTab: calls.showContactsTab, showCallsTab: calls.showTab, foldersAtBottom: experimental.foldersTabAtBottom), iconPackBackup: iconBackup)
                try FileManager.default.createDirectory(at: temporaryFile.directory, withIntermediateDirectories: true)
                let url = temporaryFile.directory.appendingPathComponent("exteragram-settings.json")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let popover = share.popoverPresentationController {
                    popover.sourceView = controller.view
                    popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
                    popover.permittedArrowDirections = []
                }
                share.completionWithItemsHandler = { [weak self] _, _, _, error in
                    temporaryFile.remove()
                    DispatchQueue.main.async {
                        self?.busy = false
                        if error != nil { self?.showError() }
                    }
                }
                controller.present(share, animated: true)
            } catch {
                temporaryFile.remove()
                self.busy = false
                self.showError()
            }
        }))
    }

    private func importSettings() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: false)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.json"], in: .open)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        self.busy = true
        self.controller?.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.busy = false
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard urls.count == 1, let url = urls.first else {
            self.busy = false
            return
        }
        // Close Files before presenting validation feedback or the confirmation dialog.
        controller.dismiss(animated: true, completion: { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ExteraSettingsBackup.validateBundle(data: Self.readDocument(url)) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    switch result {
                    case let .success(bundle):
                        do {
                            let iconPlan = try self.iconPlan(bundle)
                            self.confirmImport(bundle, iconPlan: iconPlan)
                        } catch {
                            self.showError(importing: true)
                        }
                    case .failure: self.showError(importing: true)
                    }
                }
            }
        })
    }

    private static func readDocument(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ExteraSettingsBackup.BackupError.malformed)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: { coordinatedURL in
            result = Result {
                guard coordinatedURL.isFileURL else { throw ExteraSettingsBackup.BackupError.malformed }
                let resource = try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resource.isRegularFile == true else { throw ExteraSettingsBackup.BackupError.malformed }
                if let size = resource.fileSize, size > ExteraSettingsBackup.maximumBundleFileSize {
                    throw ExteraSettingsBackup.BackupError.fileTooLarge
                }
                // Bound the read even if a file provider changes its reported size during coordination.
                guard let stream = InputStream(url: coordinatedURL) else { throw ExteraSettingsBackup.BackupError.malformed }
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while data.count <= ExteraSettingsBackup.maximumBundleFileSize {
                    let maximumRead = min(buffer.count, ExteraSettingsBackup.maximumBundleFileSize + 1 - data.count)
                    let count = stream.read(&buffer, maxLength: maximumRead)
                    guard count >= 0 else { throw stream.streamError ?? ExteraSettingsBackup.BackupError.malformed }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                guard data.count <= ExteraSettingsBackup.maximumBundleFileSize else { throw ExteraSettingsBackup.BackupError.fileTooLarge }
                return data
            }
        })
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func iconPlan(_ bundle: ExteraSettingsBackup.ValidatedBundle) throws -> ExteraUIIconPackBackupPlan? {
        guard let data = bundle.iconPackBackupData ?? bundle.settings.iconPackBackupData else { return nil }
        let plan = try ExteraUIIconPackStore.prepareBackupRestore(data)
        for preview in plan.packs {
            try ExteraUIIconRendering.validate(preview)
        }
        return plan
    }

    private func confirmImport(_ bundle: ExteraSettingsBackup.ValidatedBundle, iconPlan: ExteraUIIconPackBackupPlan?) {
        self.confirm(title: self.text("Extera.ImportSettings", "Import Settings"), message: self.text("Extera.ImportSettingsConfirm", "Replace the preferences included in this backup? Accounts, messages, and plugin preferences are kept."), destructive: false, actionTitle: self.text("Extera.ImportSettings", "Import Settings"), action: { [weak self] in
            guard let self else { return }
            do {
                try ExteraSettingsBackup.apply(bundle.settings, commit: {
                    if let iconPlan {
                        try ExteraUIIconPackStore.shared.restoreBackup(iconPlan, validate: ExteraUIIconRendering.validate)
                    }
                })
                self.applyShared(bundle.settings.sharedPreferences, reset: false, updateDownloadSpeedBoost: bundle.settings.includesDownloadSpeedBoost)
            } catch {
                self.showError(importing: true)
            }
        })
    }

    private func confirmReset() {
        self.confirm(title: self.text("Extera.ResetSettings", "Reset Settings"), message: self.text("Extera.ResetSettingsConfirm", "Reset the preferences exposed in exteraGram settings to their defaults? Accounts, messages, and plugin preferences are kept."), destructive: true, actionTitle: self.text("Extera.ResetSettings", "Reset Settings"), action: { [weak self] in
            guard let self else { return }
            do {
                try ExteraSettingsBackup.reset()
                let calls = CallListSettings.defaultSettings
                self.applyShared(.init(showContactsTab: calls.showContactsTab, showCallsTab: calls.showTab, foldersAtBottom: ExperimentalUISettings.defaultSettings.foldersTabAtBottom), reset: true, updateDownloadSpeedBoost: true)
            } catch {
                self.showMessage(title: self.text("Extera.SettingsBackup", "Settings Backup"), message: self.text("Extera.SettingsBackupResetError", "The settings could not be reset. Please try again."))
            }
        })
    }

    private func applyShared(_ shared: ExteraSettingsBackup.SharedPreferences?, reset: Bool, updateDownloadSpeedBoost: Bool) {
        self.busy = true
        var updates: [Signal<Void, NoError>] = []
        if let shared {
            updates.append(updateCallListSettingsInteractively(accountManager: self.context.sharedContext.accountManager, { current in
                if reset { return CallListSettings.defaultSettings }
                return current.withUpdatedShowContactsTab(shared.showContactsTab).withUpdatedShowTab(shared.showCallsTab)
            }))
            updates.append(updateExperimentalUISettingsInteractively(accountManager: self.context.sharedContext.accountManager, { current in
                var current = current
                current.foldersTabAtBottom = shared.foldersAtBottom
                return current
            }))
        }
        if updateDownloadSpeedBoost {
            let useExperimentalDownload = SGSimpleSettings.shared.downloadSpeedBoost != SGSimpleSettings.DownloadSpeedBoostValues.none.rawValue
            updates.append(updateNetworkSettingsInteractively(postbox: self.context.account.postbox, network: self.context.account.network, { current in
                var current = current
                current.useExperimentalDownload = useExperimentalDownload
                return current
            }))
        }
        let completion = { [self] in
            self.busy = false
            self.showMessage(title: self.text("Extera.SettingsBackup", "Settings Backup"), message: self.text("Extera.SettingsBackupApplied", "Settings updated. Restart the app to apply all changes."))
        }
        if updates.isEmpty {
            // combineLatest([]) never completes in this version of SwiftSignalKit.
            completion()
        } else {
            // A confirmed import must finish its transactions even when its screen is popped.
            // The subscriber retains this action object until completion; it is not canceled by deinit.
            let _ = (combineLatest(updates) |> deliverOnMainQueue).start(completed: completion)
        }
    }

    private func confirm(title: String, message: String, destructive: Bool, actionTitle: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: actionTitle, style: destructive ? .destructive : .default, handler: { _ in action() }))
        self.controller?.present(alert, animated: true)
    }

    private func showError(importing: Bool = false) {
        self.showMessage(title: self.text("Extera.SettingsBackup", "Settings Backup"), message: importing ? self.text("Extera.SettingsBackupImportError", "This file could not be imported. Choose a supported exteraGram settings JSON file with valid preference values.") : self.text("Extera.SettingsBackupExportError", "The settings file could not be exported. Please try again."))
    }

    private func showMessage(title: String, message: String) {
        guard self.controller?.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_OK, style: .default))
        self.controller?.present(alert, animated: true)
    }
}
