"""Structural verification on Windows; does not replace Swift/iOS execution."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Swiftgram/SGSimpleSettings/Sources"
BACKUP = (SOURCES / "ExteraSettingsBackup.swift").read_text(encoding="utf-8")
UI = (ROOT / "Swiftgram/SGSettingsUI/Sources/ExteraBackupController.swift").read_text(encoding="utf-8")


class BackupSourceChecks(unittest.TestCase):
    maxDiff = 1000
    def test_all_extera_keys_covered_explicitly(self):
        for file in ["ExteraSettings.swift", "ExteraChatSettings.swift", "ExteraMenuSettings.swift", "ExteraMessageSettings.swift"]:
            source = (SOURCES / file).read_text(encoding="utf-8")
            keys_body = re.search(r"public enum Keys[^\{]*\{(.*?)\n    \}", source, re.S).group(1)
            for key in re.findall(r"case (\w+)", keys_body):
                with self.subTest(file=file, key=key):
                    self.assertRegex(BACKUP, rf"(?:\.{key}\b|[.\"]{key}\")")

    def test_all_new_singleton_properties_covered(self):
        derived = {"resolvedTargetCurrency", "sizeCoefficient", "recentStickersLimit"}
        for file in ["ExteraGeneralSettings.swift", "ExteraMathSettings.swift", "ExteraTranslationSettings.swift", "ExteraMediaSettings.swift", "ExteraBrowserSettings.swift", "ExteraStickerSettings.swift", "ExteraPlayerSettings.swift"]:
            source = (SOURCES / file).read_text(encoding="utf-8")
            for key in re.findall(r"public var (\w+):", source):
                if key in derived:
                    continue
                with self.subTest(file=file, key=key):
                    self.assertIn(key, BACKUP, msg=f"Missing backup preference {file}:{key}")

    def test_no_domain_export_reset_or_private_keys(self):
        for forbidden in ["dictionaryRepresentation", "persistentDomain", "removePersistentDomain", "removeObject", "primaryUserId", "regDateCache", "lastAccountFolders", "outgoingLanguageTranslation", "plugin.", "AyuGhostSettings", "AyuSaveSettings", "AyuCustomizationSettings"]:
            self.assertNotIn(forbidden, BACKUP)
        self.assertNotIn("UserDefaults", BACKUP)

    def test_explicit_names_unique(self):
        names = re.findall(r'(?:Setting\(name:|boolean\(|integer\(|text\()\s*"(extera\.[^"]+)"', BACKUP)
        for helper, name in re.findall(r'\b(simpleBoolean|simpleInteger|simpleString|exteraBoolean)\(\.(\w+)', BACKUP):
            names.append(("extera." if helper == "exteraBoolean" else "simple.") + name)
        self.assertEqual(len(names), len(set(names)))

    def test_validation_does_not_write(self):
        validation = BACKUP.split("public static func validate(data:", 1)[1].split("public static func apply", 1)[0]
        for forbidden in [".shared", "setting.write", ".set(", "didChange()"]:
            self.assertNotIn(forbidden, validation)
        self.assertIn("rejectDuplicateKeys(data)", validation)
        self.assertIn("CFGetTypeID(number) == CFBooleanGetTypeID()", BACKUP)
        self.assertIn("CFGetTypeID(number) != CFBooleanGetTypeID()", BACKUP)
        self.assertIn("guard let setting = self.settingsByName[name] else", validation)

    def test_partial_import_does_not_update_download_transport(self):
        self.assertIn('self.values["simple.downloadSpeedBoost"] != nil', BACKUP)
        self.assertIn("updateDownloadSpeedBoost: backup.includesDownloadSpeedBoost", UI)
        self.assertIn("if updateDownloadSpeedBoost {", UI)
        self.assertIn("if updates.isEmpty {", UI)

    def test_confirmed_transactions_outlive_controller(self):
        update = UI.split("private func applyShared", 1)[1].split("private func confirm(", 1)[0]
        self.assertIn("let completion = { [self] in", update)
        self.assertNotIn("self.operation.set", update)

    def test_utf8_grammar_and_temp_fallback_cleanup(self):
        self.assertIn("String(data: data, encoding: .utf8) != nil", BACKUP)
        self.assertIn("self.index == self.bytes.count", BACKUP)
        self.assertIn("guard depth < 16", BACKUP)
        temporary_file = UI.split("private final class ExteraBackupTemporaryFile", 1)[1].split("public func exteraBackupController", 1)[0]
        self.assertIn("deinit {", temporary_file)
        self.assertIn("self.remove()", temporary_file)
        self.assertIn("InputStream(url: coordinatedURL)", UI)
        self.assertNotIn("file.readData", UI)

    def test_import_reset_batch_and_synchronize_once(self):
        for marker, following in [("public static func apply(", "public static func reset("), ("public static func reset(", "private static func rejectDuplicateKeys(")]:
            body = BACKUP.split(marker, 1)[1].split(following, 1)[0]
            self.assertEqual(body.count("AyuSettingsStore.shared.performBatchUpdates"), 1)
            self.assertEqual(body.count("SGSimpleSettings.shared.synchronizeShared()"), 1)
        self.assertNotIn("NotificationCenter.default.post", BACKUP)

    def test_native_file_flow_and_confirmation(self):
        for expected in ["public func exteraBackupController(context: AccountContext)", "UIActivityViewController", "UIDocumentPickerViewController", "startAccessingSecurityScopedResource", "stopAccessingSecurityScopedResource", "NSFileCoordinator", "maximumFileSize + 1", "confirmReset()", "confirmImport(backup)", "ExteraSettingsBackup.apply(backup)", "ExteraSettingsBackup.reset()", "withUpdatedShowContactsTab", "foldersTabAtBottom", "useExperimentalDownload"]:
            self.assertIn(expected, UI)
        reset = UI.split("private func confirmReset()", 1)[1].split("private func applyShared", 1)[0]
        self.assertLess(reset.index("self.confirm("), reset.index("ExteraSettingsBackup.reset()"))

    def test_source_globs_cover_both_new_files(self):
        for module in ["SGSettingsUI", "SGSimpleSettings"]:
            self.assertIn('"Sources/**/*.swift"', (ROOT / "Swiftgram" / module / "BUILD").read_text())

    def test_sticker_slider_range_matches_validation(self):
        slider = (ROOT / "Swiftgram/SGItemListUI/Sources/SliderPercentageItem.swift").read_text()
        self.assertIn("range: 0.0 ... 100.0", slider)
        self.assertIn("simpleInteger(.stickerSize, \\.stickerSize, range: 0 ... 100", BACKUP)


if __name__ == "__main__":
    unittest.main(verbosity=2)
