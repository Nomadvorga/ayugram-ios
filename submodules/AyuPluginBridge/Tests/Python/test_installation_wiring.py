"""Source integration guards; never import or execute a .plugin attachment.

These checks cover routing and authorization seams unavailable to host Python
tests. Swift compilation, service behavior and simulator acceptance remain
separate checks; these assertions do not substitute for them.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[4]
BRIDGE = ROOT / "submodules" / "AyuPluginBridge" / "Integration"


def read(path):
    return path.read_text(encoding="utf-8")


def section(source, start, end):
    """Bound failures to the missing marker, never print a whole Swift file."""
    first = source.find(start)
    if first < 0:
        raise AssertionError(f"Missing start marker: {start}")
    last = source.find(end, first + len(start))
    if last < 0:
        raise AssertionError(f"Missing end marker: {end}")
    return source[first:last]


class InstallationWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.detail = read(BRIDGE / "AyuPluginDetailViewController.swift")
        cls.manager = read(BRIDGE / "AyuPluginManagerViewController.swift")
        cls.service = read(BRIDGE / "AyuPluginService.swift")
        cls.chat = read(ROOT / "submodules/TelegramUI/Sources/OpenChatMessage.swift")

    def contains(self, source, fragment):
        self.assertTrue(fragment in source, f"Missing wiring: {fragment}")

    def excludes(self, source, fragment):
        self.assertFalse(fragment in source, f"Unexpected wiring: {fragment}")

    def test_chat_attachment_opens_preview_without_installing_or_enabling(self):
        route = section(self.chat, 'if !immediateShare, let fileName', '\n                let presentationData =')
        self.contains(route, '["plugin", "elyx", "eaf"].contains((fileName as NSString).pathExtension.lowercased())')
        self.contains(route, "AyuPluginDetailViewController(fileName: fileName)")
        self.contains(route, "presenter.present(navigationController, animated: true)")
        for forbidden in ("importPlugin(", "service.enable(", "runtime.load(", "UndoOverlayController("):
            self.excludes(route, forbidden)

    def test_chat_attachment_is_not_opened_while_the_engine_is_off(self):
        route = section(self.chat, 'if !immediateShare, let fileName', '\n                let presentationData =')
        guard = route.find("guard AyuPluginManagerViewController.isEngineEnabled else {")
        self.assertGreater(guard, 0, "Missing wiring: the engine guard")
        self.assertLess(guard, route.find("AyuPluginDetailViewController(fileName: fileName)"))
        self.contains(section(route, "guard AyuPluginManagerViewController.isEngineEnabled else {", "}"), "presentAyuPluginEngineNotice(")
        notice = read(ROOT / "submodules/TelegramUI/Sources/AyuPluginEngineNotice.swift")
        self.contains(notice, 'customUndoText: "Включить"')
        self.contains(notice, "ayuPluginManagerController(context: context)")
        for forbidden in ("importPlugin(", ".enable(", "AyuPluginDetailViewController("):
            self.excludes(notice, forbidden)
        self.contains(self.manager, "UserDefaults.standard.bool(forKey: Self.engineKey)")

    def test_download_waits_for_complete_bytes_and_has_cancellation(self):
        route = section(self.chat, 'if !immediateShare, let fileName', '\n                let presentationData =')
        self.contains(route, "resources.fetch(")
        self.contains(route, "filter { $0.isComplete }")
        self.contains(route, "|> take(1)")
        self.contains(route, "detail?.loadPlugin(from: URL(fileURLWithPath: data.path))")
        self.contains(route, "detail?.sourceUnavailable()")
        self.contains(route, "detail.cancelSourceRequest = { requests.dispose() }")
        cleanup = section(self.detail, "isolated deinit {", "public override func viewDidLoad()")
        self.contains(cleanup, "self.cancelSourceRequest?()")
        self.contains(cleanup, "removeItem(at: stagedURL.deletingLastPathComponent())")

    def test_document_picker_routes_single_preview_or_confirmed_multi_import(self):
        picker = section(self.manager, "public func documentPicker(", "private func openDetail(")
        self.contains(picker, "AyuPluginDetailViewController(sourceURL: url, service: self.service)")
        self.contains(self.manager, "picker.allowsMultipleSelection = true")
        self.contains(picker, "if urls.count == 1, let url = urls.first")
        self.contains(picker, "self.confirmImportBatch(urls)")
        self.contains(picker, "controller.dismiss(animated: true)")
        self.excludes(picker, "importPlugin(")
        self.excludes(picker, ".enable(")

    def test_multi_document_import_is_explicit_sequential_and_never_auto_enables(self):
        confirmation = section(self.manager, "private func confirmImportBatch(", "private func runImportBatch(")
        self.contains(confirmation, "urls.count <= AyuPluginCapacity.maximumInstalledPlugins")
        self.contains(confirmation, "UIAlertAction(title: \"Установить выключенными\"")
        self.contains(confirmation, "self?.runImportBatch(urls)")
        self.contains(confirmation, "Все они останутся выключенными")
        self.contains(confirmation, "Повторные ID и существующие плагины будут пропущены без замены")
        self.excludes(confirmation, ".enable(")

        import_batch = section(self.manager, "private func runImportBatch(", "private func confirmBatch(")
        self.contains(import_batch, "self.service.importBatch(from: urls")
        self.contains(import_batch, "isCancelled:")
        self.contains(import_batch, "progress:")
        self.contains(import_batch, "Installed disabled:")
        self.excludes(import_batch, ".enable(")

        service_import_batch = section(self.service, "public func importBatch(", "nonisolated private static let maximumPendingImports")
        self.contains(service_import_batch, "for (index, url) in urls.enumerated()")
        self.contains(service_import_batch, "importPlugin(from:")
        self.contains(service_import_batch, "expectedSHA256: preview.sourceSHA256")
        self.excludes(service_import_batch, "self.enable(")
        self.excludes(service_import_batch, "self.enableBatch(")

    def test_inspection_has_no_install_or_execution(self):
        loader = section(self.detail, "public func loadPlugin(", "public func sourceUnavailable()")
        self.contains(loader, "self.service.previewPlugin(from: stagedURL)")
        self.excludes(loader, "importPlugin(")
        self.excludes(loader, ".enable(")
        preview = section(self.service, "public func previewPlugin(", "public func importPlugin(")
        self.contains(preview, "self.inspect(source)")
        for forbidden in ("runtime.load(", "self.enable(", "self.plugins.append(", ".write(to:"):
            self.excludes(preview, forbidden)

    def test_staging_is_bounded_regular_utf8_with_real_plugin_extension(self):
        stage = section(self.detail, "nonisolated private static func stage(", "public override func numberOfSections(")
        for required in ('let fileExtension = (fileName as NSString).pathExtension.lowercased()',
                         'guard isPackage || fileExtension == "plugin" else { throw AyuPluginService.Failure.source }',
                         "flags.isRegularFile == true",
                         "flags.isSymbolicLink != true", "read(upToCount: AyuPluginService.maximumSourceBytes + 1)",
                         "source.count <= AyuPluginService.maximumSourceBytes", "String(data: source, encoding: .utf8) != nil",
                         'appendingPathComponent("preview." + fileExtension)'):
            self.contains(stage, required)
        # A package archive is copied in pieces under its own bound and never decoded as text.
        for required in ("let isPackage = AyuPluginService.packageExtensions.contains(fileExtension)",
                         "if isPackage { try Self.copyPackage(from: handle, to: destination) }",
                         "guard total <= AyuPluginService.maximumPackageBytes else { throw AyuPluginService.Failure.source }",
                         "guard total > 0 else { throw AyuPluginService.Failure.source }"):
            self.contains(stage, required)
        self.contains(self.service, "nonisolated public static let maximumSourceBytes = 4_194_304")
        self.contains(self.service, "nonisolated public static let maximumPackageBytes = 67_108_864")
        self.contains(self.service, 'nonisolated public static let packageExtensions = ["elyx", "eaf"]')
        self.excludes(stage, "1_048_577")
        self.excludes(stage, "data.count <= 1_048_576")

    def test_install_rechecks_preview_hash_before_committing(self):
        install = section(self.detail, "private func confirmInstall(", "private func confirmEnable(")
        self.contains(install, "expectedSHA256: preview.sourceSHA256")
        self.contains(install, "replacingExisting: replacingExisting")
        self.excludes(install, ".enable(")
        service_import = section(self.service, "public func importPlugin(", "nonisolated private static func importSource(")
        self.contains(service_import, "source.sha256 != expectedSHA256")
        self.contains(service_import, "throw Failure.sourceChanged")
        self.assertLess(service_import.index("throw Failure.sourceChanged"),
                        service_import.index("try Self.store(source, record: record, root: root, replacingExisting: replacingExisting)"),
                        "Hash must be checked before storage writes")
        self.excludes(service_import, ".write(to:")
        # The hash of a package is the hash of the staged copy that is inspected and then moved into place.
        stage = section(self.service, "nonisolated private static func stagePackage(", "nonisolated private static func packageDigest(")
        for required in ("try Self.requireRegularFile(url)", "guard total <= Self.maximumPackageBytes else { throw Failure.source }",
                         "hasher.update(data: chunk)", "try output.write(contentsOf: chunk)"):
            self.contains(stage, required)
        store = section(self.service, "nonisolated private static func store(", "nonisolated private static func removeUnpackedPackage(")
        self.contains(store, "case let .package(archive, _, _): try manager.moveItem(at: archive, to: target)")
        self.contains(store, "try manager.moveItem(at: previous.parked, to: previous.url)")

    def test_replacement_requires_disabled_idle_plugin_and_preserves_preferences(self):
        install = section(self.detail, "private func confirmInstall(", "private func confirmEnable(")
        self.contains(install, "self.installed?.isBusy != true")
        self.contains(install, "self.installed?.isEnabled != true")
        service_import = section(self.service, "public func importPlugin(", "nonisolated private static func importSource(")
        self.contains(service_import, "guard !existing.isBusy else")
        self.contains(service_import, "guard !existing.isEnabled else")
        for forbidden in ("self.defaults.removeObject(", "self.delete(", "runtime.load(", "self.enable("):
            self.excludes(service_import, forbidden)

    def test_detail_preserves_metadata_after_reopening_installed_plugin(self):
        for required in ('self.preview?.author ?? plugin.author ?? ""',
                         'self.preview?.description ?? plugin.description ?? ""',
                         "self.preview?.requirements ?? plugin.requirements ?? []",
                         "requirements.prefix(64).map", "plugin.blockers.prefix(64).map"):
            self.contains(self.detail, required)

    def test_enable_requires_explicit_confirmation_and_settings_have_a_route(self):
        enable = section(self.detail, "private func confirmEnable(", "private func confirmDelete(")
        self.contains(enable, "UIAlertController(")
        self.contains(enable, "style: .cancel")
        self.contains(enable, "self?.service.enable(plugin.id)")
        self.contains(self.detail, "pushViewController(AyuPluginSettingsViewController(")
        self.contains(self.detail, "AyuPluginManagerViewController(service: self.service)")

    def test_list_card_switch_asks_for_consent_and_other_card_actions_never_enable(self):
        card = section(self.manager, "private func perform(_ action: AyuPluginCell.Action", "private func confirmEnable(")
        self.contains(card, "guard !self.batchRunning, !self.batchSelecting")
        self.contains(card, "else if plugin.blockers.isEmpty { self.confirmEnable(plugin) }")
        self.contains(card, "AyuPluginAlerts.deleteConfirmation(for: plugin)")
        self.excludes(card, ".enable(")
        consent = section(self.manager, "private func confirmEnable(", "private func run(")
        self.contains(consent, "AyuPluginAlerts.enableConsent(for: plugin)")
        self.contains(consent, "style: .cancel")
        self.contains(consent, "service.enable(plugin.id)")
        self.assertEqual(self.manager.count(".enable("), 1, "The list has one enable call, behind the consent alert")
        share = section(self.service, "public func exportCopy(", "public func settings(")
        self.contains(share, "try Self.requireRegularFile(stored)")
        for forbidden in ("runtime.", "self.enable(", "importPlugin("):
            self.excludes(share, forbidden)
        cell = read(BRIDGE / "AyuPluginCell.swift")
        for forbidden in ("AyuPluginService", ".enable(", ".disable(", ".delete("):
            self.excludes(cell, forbidden)

    def test_settings_notifications_are_host_owner_and_generation_scoped(self):
        settings = section(self.manager, "@MainActor final class AyuPluginSettingsViewController:",
                           "@MainActor final class AyuPluginPreviewViewController:")
        self.contains(settings, "name: AyuPluginNativeHost.settingsDidChange, object: self.service.host")
        self.contains(settings, "isolated deinit { NotificationCenter.default.removeObserver(self) }")
        handler = section(settings, "@objc private func settingsChanged(", "private func reload()")
        self.contains(handler, 'notification.userInfo?["pluginID"] as? String, owner == self.plugin.id')
        self.contains(handler, 'notification.userInfo?["generation"] as? String')
        self.contains(handler, "self.service.shouldReloadSettings(pluginID: owner, generation: generation)")
        self.assertLess(handler.index("self.service.shouldReloadSettings("),
                        handler.index("self.reload()"), "Validate notification before requesting reload")

    def test_settings_notifications_coalesce_and_recheck_queued_generation(self):
        settings = section(self.manager, "@MainActor final class AyuPluginSettingsViewController:",
                           "@MainActor final class AyuPluginPreviewViewController:")
        reload = section(settings, "private func reload()", "private func finishRowOperation()")
        self.contains(reload, "guard !self.loading else { self.reloadRequested = true; return }")
        self.contains(reload, "if let generation = self.pendingReloadGeneration")
        self.contains(reload, "self.service.shouldReloadSettings(pluginID: self.plugin.id, generation: generation)")
        self.contains(reload, "self.pendingReloadGeneration = nil")
        self.contains(reload, "self.finishRowOperation()")
        finish = section(settings, "private func finishRowOperation()", "override func tableView(")
        self.contains(finish, "if self.reloadRequested")
        self.assertLess(finish.index("self.loading = false"), finish.index("self.reload()"),
                        "Release the operation before draining the pending reload")
        self.assertLess(finish.index("self.reloadRequested = false"), finish.index("self.reload()"),
                        "Drain one coalesced reload, not one per notification")

    def test_settings_save_finishes_before_pending_reload_can_replace_rows(self):
        settings = section(self.manager, "@MainActor final class AyuPluginSettingsViewController:",
                           "@MainActor final class AyuPluginPreviewViewController:")
        save = settings[settings.index("private func save("):]
        self.contains(save, "!self.loading")
        self.contains(save, "self.loading = true; self.tableView.isUserInteractionEnabled = false")
        self.assertLess(save.index("try await self.service.set("), save.index("self.rows[index].value = value"),
                        "Finish persistence before applying the edited row")
        self.assertLess(save.index("self.rows[index].value = value"), save.index("self.finishRowOperation()"),
                        "Finish the edited row before draining notification reloads")


if __name__ == "__main__":
    unittest.main()
