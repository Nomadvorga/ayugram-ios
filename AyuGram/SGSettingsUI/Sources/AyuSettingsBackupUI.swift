import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import AccountContext
import TelegramUIPreferences
import TelegramPresentationData
import PresentationDataUtils
import SGSimpleSettings
import SGStrings
import AyuSettingsBackup

// MARK: AyuGram
// Export and import of the ".extera" settings backup (exteraGram's format, see AyuSettingsBackup).

private final class AyuBackupPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let picked: (URL) -> Void

    init(picked: @escaping (URL) -> Void) {
        self.picked = picked
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        ayuBackupPickerDelegate = nil
        if let url = urls.first {
            self.picked(url)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        ayuBackupPickerDelegate = nil
    }
}

// The picker does not retain its delegate; this keeps it for as long as the picker is on screen.
private var ayuBackupPickerDelegate: AyuBackupPickerDelegate?

private func ayuBackupPresenter(_ controller: ViewController) -> UIViewController? {
    var top = controller.view.window?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

private func ayuBackupAlert(context: AccountContext, from controller: ViewController, title: String? = nil, text: String) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller.present(textAlertController(context: context, title: title, text: text, actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ]), in: .window(.root))
}

// The table of settings with the switches the account manager keeps, read once.
private func ayuBackupSchema(context: AccountContext) -> Signal<ExteraBackupSchema, NoError> {
    let accountManager = context.sharedContext.accountManager
    return accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings])
    |> take(1)
    |> deliverOnMainQueue
    |> map { sharedData -> ExteraBackupSchema in
        let callListSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings
        let experimentalUISettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
        return ExteraSettings.shared.backupSchema(accountSwitches: [
            .showContactsTab: callListSettings.showContactsTab,
            .showCallsTab: callListSettings.showTab,
            .foldersAtBottom: experimentalUISettings.foldersTabAtBottom
        ], setAccountSwitch: { accountSwitch, value in
            switch accountSwitch {
            case .showContactsTab:
                let _ = updateCallListSettingsInteractively(accountManager: accountManager, { $0.withUpdatedShowContactsTab(value) }).start()
            case .showCallsTab:
                let _ = updateCallListSettingsInteractively(accountManager: accountManager, { $0.withUpdatedShowTab(value) }).start()
            case .foldersAtBottom:
                let _ = updateExperimentalUISettingsInteractively(accountManager: accountManager, { current in
                    var current = current
                    current.foldersTabAtBottom = value
                    return current
                }).start()
            }
        })
    }
}

func ayuExportSettingsBackup(context: AccountContext, from controller: ViewController) {
    let _ = ayuBackupSchema(context: context).start(next: { [weak controller] schema in
        guard let controller else {
            return
        }
        ayuExportSettingsBackup(context: context, schema: schema, from: controller)
    })
}

private func ayuExportSettingsBackup(context: AccountContext, schema: ExteraBackupSchema, from controller: ViewController) {
    let lang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
    let document = schema.export()
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(ExteraBackupDocument.generateName())
    do {
        try document.fileData().write(to: url, options: .atomic)
    } catch {
        ayuBackupAlert(context: context, from: controller, text: i18n("Extera.BackupExportFailed", lang))
        return
    }
    guard let presenter = ayuBackupPresenter(controller) else {
        return
    }
    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    share.completionWithItemsHandler = { _, _, _, _ in
        try? FileManager.default.removeItem(at: url)
    }
    if let popover = share.popoverPresentationController {
        popover.sourceView = controller.view
        popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
        popover.permittedArrowDirections = []
    }
    presenter.present(share, animated: true)
}

// `applied` runs after values were stored.
func ayuImportSettingsBackup(context: AccountContext, from controller: ViewController, applied: @escaping () -> Void) {
    guard let presenter = ayuBackupPresenter(controller) else {
        return
    }
    var types: [UTType] = [.data]
    if let backupType = UTType(filenameExtension: ExteraBackupDocument.fileExtension), backupType != .data {
        types.insert(backupType, at: 0)
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    let delegate = AyuBackupPickerDelegate(picked: { [weak controller] url in
        guard let controller else {
            return
        }
        let _ = ayuBackupSchema(context: context).start(next: { [weak controller] schema in
            guard let controller else {
                return
            }
            ayuApplySettingsBackup(context: context, schema: schema, url: url, from: controller, applied: applied)
        })
    })
    ayuBackupPickerDelegate = delegate
    picker.delegate = delegate
    presenter.present(picker, animated: true)
}

private func ayuApplySettingsBackup(context: AccountContext, schema: ExteraBackupSchema, url: URL, from controller: ViewController, applied: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode

    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard size <= ExteraBackupDocument.maxFileSize, let data = try? Data(contentsOf: url), let document = ExteraBackupDocument(fileData: data), schema.recognizes(document) else {
        ayuBackupAlert(context: context, from: controller, text: i18n("Extera.BackupNotABackup", lang))
        return
    }
    let count = schema.differenceCount(document)
    if count == 0 {
        ayuBackupAlert(context: context, from: controller, text: i18n("Extera.BackupNothingToChange", lang))
        return
    }
    controller.present(textAlertController(context: context, title: i18n("Extera.ImportSettings", lang), text: "Extera.BackupImportConfirm".i18n(lang, args: "\(count)"), actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .defaultAction, title: i18n("Extera.BackupApply", lang), action: {
            schema.apply(document)
            applied()
        })
    ]), in: .window(.root))
}
