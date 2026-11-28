import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SettingsUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private typealias OtherModel = ExteraOtherSettingsModel
private struct OtherSection: SGItemListSection {
    let value: OtherModel.Section
    var rawValue: Int32 { return self.value.rawValue }
    static let exteraSupport = OtherSection(value: .exteraSupport)
    static let ayuSupport = OtherSection(value: .ayuSupport)
    static let google = OtherSection(value: .google)
    static let account = OtherSection(value: .account)
    static let additional = OtherSection(value: .additional)
}

private enum OtherAction: Hashable {
    case support(OtherModel.SupportEntry), retrySupport, exportSettings, resetSettings, deleteAccount, additional
}
private typealias OtherRow = SGItemListUIEntry<OtherSection, Int, Int, Int, OtherAction, OtherAction>
private typealias OtherArguments = SGItemListArguments<Int, Int, Int, OtherAction, OtherAction>

/// UIAlertController owns dismissal after an action handler returns. On the next main turn its
/// transition coordinator is available (or dismissal has already finished/was not animated).
/// Never attach the action to a second dismiss call: UIKit can ignore it during auto-dismissal.
private func exteraOtherAfterAlertAction(_ alert: UIAlertController?, action: @escaping () -> Void) {
    DispatchQueue.main.async {
        var completed = false
        let complete: () -> Void = {
            guard !completed else { return }
            completed = true
            action()
        }
        guard let coordinator = alert?.transitionCoordinator, coordinator.isAnimated else {
            complete()
            return
        }
        if !coordinator.animate(alongsideTransition: nil, completion: { _ in complete() }) {
            // No completion is registered when the coordinator declines the block.
            complete()
        }
    }
}

private enum OtherEntry: ItemListNodeEntry {
    case row(OtherRow)
    case telemetry(id: Int, service: OtherModel.Telemetry, status: String)

    var stableId: Int { switch self { case let .row(row): return row.stableId; case let .telemetry(id, _, _): return id } }
    var section: ItemListSectionId { switch self { case let .row(row): return row.section; case .telemetry: return OtherModel.Section.google.rawValue } }
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .row(row): return row.item(presentationData: presentationData, arguments: arguments)
        case let .telemetry(_, service, status):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: generateTintedImage(image: UIImage(systemName: service == .crashlytics ? "exclamationmark.circle" : "chart.pie"), color: presentationData.theme.list.itemSecondaryTextColor), title: service.rawValue, enabled: service.canCollect, label: status, sgLabelMaximumNumberOfLines: 2, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {})
        }
    }
}

/// Root supplies the existing backup actions so export/reset keep one implementation and scope.
/// Constructing this page never opens a security controller or starts an account mutation.
public func exteraOtherSettingsController(context: AccountContext, backupAction: @escaping (ViewController, ExteraOtherSettingsModel.SettingsAction) -> Void, additionalSettings: @escaping () -> ViewController) -> ViewController {
    let support = ExteraOtherSupportContext(context: context)
    let actions = ExteraOtherActions(context: context, support: support, backupAction: backupAction, additionalSettings: additionalSettings)
    let arguments = OtherArguments(context: context, visualStyle: .extera, openDisclosureLink: { actions.perform($0) }, action: { actions.perform($0) })
    let signal = combineLatest(context.sharedContext.presentationData, support.state.get(), actions.loadingState.get())
    |> deliverOnMainQueue
    |> map { presentationData, snapshot, loadingDeletion -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        func text(_ key: String, _ fallback: String) -> String { return i18n("Extera.Other." + key, lang, fallback) }
        var entries: [OtherEntry] = []
        var id = 0
        func row(_ make: (Int) -> OtherRow) { entries.append(.row(make(id))); id += 1 }
        for (project, section, name) in [(OtherModel.Project.extera, OtherSection.exteraSupport, "exteraGram"), (.ayu, .ayuSupport, "AyuGram")] {
            // Catalog length must not change identities in later sections or the status footer.
            let baseId = Int(section.rawValue) * 100
            id = baseId
            row { .header(id: $0, section: section, text: text("Support", "Support") + " (" + name + ")", badge: nil) }
            if let config = snapshot.configurations[project], !config.entries.isEmpty {
                for entry in config.entries {
                    let lower = entry.name.lowercased()
                    let icon = lower.contains("boosty") ? "bolt.fill" : (lower.contains("keeper") || lower.contains("wallet") ? "diamond.fill" : "creditcard")
                    row { .disclosureSubtitle(id: $0, section: section, link: .support(entry), text: entry.name, subtitle: "", iconName: icon) }
                }
                id = baseId + 90
                row { .notice(id: $0, section: section, text: text("SupportInfo", "Support development. Available supporter rewards and their terms are described by each project on its payment page.")) }
            } else {
                id = baseId + 90
                row { .notice(id: $0, section: section, text: snapshot.loading ? text("LoadingSupport", "Loading support options…") : text("SupportUnavailable", "Support options could not be loaded. No payment details are stored in this app.")) }
            }
        }
        if !snapshot.loading && OtherModel.Project.allCases.contains(where: { snapshot.configurations[$0]?.entries.isEmpty != false }) {
            id = Int(OtherSection.ayuSupport.rawValue) * 100 + 99
            row { .action(id: $0, section: .ayuSupport, actionType: .retrySupport, text: text("RefreshSupport", "Refresh Support Options"), kind: .generic) }
        }
        id = Int(OtherSection.google.rawValue) * 100
        row { .header(id: $0, section: .google, text: "Google", badge: nil) }
        for service in OtherModel.Telemetry.allCases {
            entries.append(.telemetry(id: id, service: service, status: text("NotIncluded", "Not included")))
            id += 1
        }
        row { .notice(id: $0, section: .google, text: text("TelemetryInfo", "This iOS build does not include Google Analytics or Crashlytics collection. These services cannot be enabled here. This does not control Telegram service logs or Apple's system diagnostics, and does not erase data previously sent by other apps or builds.")) }
        // Frame 67: one card, exactly export → reset → delete. Import stays in Settings Backup.
        id = Int(OtherSection.account.rawValue) * 100
        for action in OtherModel.AccountRow.allCases {
            switch action {
            case .exportSettings:
                row { .action(id: $0, section: .account, actionType: .exportSettings, text: i18n("Extera.ExportSettings", lang, "Export Settings"), kind: .generic) }
            case .resetSettings:
                row { .action(id: $0, section: .account, actionType: .resetSettings, text: i18n("Extera.ResetSettings", lang, "Reset Settings"), kind: .generic) }
            case .deleteAccount:
                row { .action(id: $0, section: .account, actionType: .deleteAccount, text: presentationData.strings.DeleteAccount_DeleteMyAccount, kind: .destructive) }
            }
        }
        if loadingDeletion {
            row { .notice(id: $0, section: .account, text: text("LoadingAccount", "Loading account security configuration…")) }
        }
        id = Int(OtherSection.additional.rawValue) * 100
        row { .header(id: $0, section: .additional, text: text("Additional", "Additional Settings"), badge: nil) }
        row { .disclosure(id: $0, section: .additional, link: .additional, text: text("Additional", "Additional Settings")) }
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Ayu.CategoryOther", lang, "Other")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    actions.controller = controller
    support.reload()
    return controller
}

private final class ExteraOtherActions {
    private let context: AccountContext
    private let support: ExteraOtherSupportContext
    private let backupAction: (ViewController, OtherModel.SettingsAction) -> Void
    private let additionalSettings: () -> ViewController
    private let operation = MetaDisposable()
    private var loadingDeletion = false
    let loadingState = ValuePromise(false, ignoreRepeated: true)
    weak var controller: ViewController?

    init(context: AccountContext, support: ExteraOtherSupportContext, backupAction: @escaping (ViewController, OtherModel.SettingsAction) -> Void, additionalSettings: @escaping () -> ViewController) {
        self.context = context
        self.support = support
        self.backupAction = backupAction
        self.additionalSettings = additionalSettings
    }
    deinit { self.operation.dispose() }

    private func text(_ key: String, _ fallback: String) -> String {
        return i18n("Extera.Other." + key, self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode, fallback)
    }
    func perform(_ action: OtherAction) {
        guard let controller = self.controller, controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil, !self.loadingDeletion else { return }
        switch action {
        case .retrySupport: self.support.reload()
        case .exportSettings: self.backupAction(controller, .exportSettings)
        case .resetSettings: self.backupAction(controller, .resetSettings)
        case .additional: controller.push(self.additionalSettings())
        case .deleteAccount: self.confirmDeleteAccount()
        case let .support(entry): self.openSupport(entry)
        }
    }

    private func openSupport(_ entry: OtherModel.SupportEntry) {
        guard !self.support.snapshot.loading,
            let config = self.support.snapshot.configurations[entry.project], config.entries.contains(entry),
            let route = OtherModel.route(for: entry, banks: config.banks, accountId: self.context.account.peerId.id._internalGetInt64Value()) else { return }
        switch route {
        case let .web(url):
            self.confirm(title: entry.name, message: url.absoluteString, actionTitle: self.text("Open", "Open"), destructive: false) { [weak self] in
                guard let self, let controller = self.controller else { return }
                self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: url.absoluteString, forceExternal: false, presentationData: self.context.sharedContext.currentPresentationData.with { $0 }, navigationController: controller.navigationController as? NavigationController, dismissInput: {})
            }
        case let .wallet(url, address, comment):
            let message = self.text("WalletConfirm", "Open your wallet with this destination and your Telegram account ID as the payment comment? Review the amount and confirm any transfer in your wallet.") + "\n\n" + address + "\n\n" + self.text("PaymentComment", "Payment comment") + ": " + comment
            self.confirm(title: entry.name, message: message, actionTitle: self.text("OpenWallet", "Open Wallet"), destructive: false) { [weak self] in
                UIApplication.shared.open(url, options: [:], completionHandler: { opened in
                    DispatchQueue.main.async {
                        guard !opened, let self else { return }
                        self.confirm(title: entry.name, message: self.text("WalletUnavailable", "No wallet could open this link. Copy the destination address instead? The payment comment is your Telegram account ID.") + "\n\n" + address + "\n\n" + comment, actionTitle: self.text("CopyAddress", "Copy Address"), destructive: false) { UIPasteboard.general.string = address }
                    }
                })
            }
        case let .banks(banks):
            guard let controller = self.controller else { return }
            let sheet = UIAlertController(title: entry.name, message: nil, preferredStyle: .actionSheet)
            for bank in banks {
                sheet.addAction(UIAlertAction(title: bank.name, style: .default, handler: { [weak self, weak sheet] _ in
                    exteraOtherAfterAlertAction(sheet) { self?.confirmCopy(name: bank.name, details: bank.details) }
                }))
            }
            sheet.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = controller.view
                popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
                popover.permittedArrowDirections = []
            }
            controller.present(sheet, animated: true)
        case let .copy(details): self.confirmCopy(name: entry.name, details: details)
        }
    }

    private func confirmCopy(name: String, details: String) {
        self.confirm(title: name, message: details, actionTitle: self.text("CopyDetails", "Copy Details"), destructive: false) { UIPasteboard.general.string = details }
    }

    private func confirmDeleteAccount() {
        guard !self.context.isFrozen else { return }
        let strings = self.context.sharedContext.currentPresentationData.with { $0 }.strings
        let accountId = self.context.account.peerId.id._internalGetInt64Value()
        self.confirm(title: strings.DeleteAccount_DeleteMyAccount, message: self.text("DeleteIntro", "Continue to Telegram's account deletion options for the current account? Nothing is deleted on this screen. Telegram will explain the consequences and require further confirmation.") + "\n\nID: " + String(accountId), actionTitle: self.text("Continue", "Continue"), destructive: true) { [weak self] in
            self?.loadDeletionOptions()
        }
    }

    private func loadDeletionOptions() {
        guard let controller = self.controller, let navigation = controller.navigationController as? NavigationController,
            controller.viewIfLoaded?.window != nil, !self.context.isFrozen, !self.loadingDeletion else { return }
        self.loadingDeletion = true
        self.loadingState.set(true)
        // Unknown/timeout must not be treated as "no password". Only a server configuration can
        // construct the native options, which retain phone/password, hierarchy and final RPC gates.
        self.operation.set((self.context.engine.auth.twoStepVerificationConfiguration()
        |> map { Optional($0) }
        |> take(1)
        |> timeout(12.0, queue: .mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { [weak self, weak controller, weak navigation] configuration in
            guard let self else { return }
            self.loadingDeletion = false
            self.loadingState.set(false)
            guard let controller, let navigation, controller.viewIfLoaded?.window != nil,
                controller.navigationController === navigation, !self.context.isFrozen else { return }
            guard let configuration else {
                self.confirm(title: self.text("DeleteUnavailable", "Could Not Load Account Options"), message: self.text("DeleteRetry", "Check your connection and try again. Your account has not been changed."), actionTitle: self.text("Retry", "Retry"), destructive: false) { [weak self] in self?.loadDeletionOptions() }
                return
            }
            let access = TwoStepVerificationAccessConfiguration(configuration: configuration, password: nil)
            let hasPassword: Bool
            switch configuration { case .set: hasPassword = true; case .notSet: hasPassword = false }
            controller.push(deleteAccountOptionsController(context: self.context, navigationController: navigation, hasTwoStepAuth: hasPassword, twoStepAuthData: access))
        }))
    }

    private func confirm(title: String, message: String, actionTitle: String, destructive: Bool, action: @escaping () -> Void) {
        guard let controller = self.controller, controller.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: actionTitle, style: destructive ? .destructive : .default, handler: { [weak alert] _ in
            exteraOtherAfterAlertAction(alert, action: action)
        }))
        controller.present(alert, animated: true)
    }
}
