import Foundation

public struct VoskModelDescriptor: Equatable, Sendable {
    public let language: String
    public let name: String
    public let archiveBytes: Int64
    public let sha256: String
    public let md5: String
    public let expandedBytes: Int
    public let largestEntryBytes: Int
    public let entryCount: Int
    public let license: String

    public var url: URL { URL(string: "https://alphacephei.com/vosk/models/\(self.name).zip")! }

    /// The exact Portuguese/Turkish 0.3 archives use Vosk's legacy flat layout.
    var requiredFiles: [String] {
        if self.name == "vosk-model-small-pt-0.3" || self.name == "vosk-model-small-tr-0.3" {
            return ["final.mdl", "mfcc.conf", "HCLr.fst", "Gr.fst"]
        }
        return ["am/final.mdl", "conf/model.conf"]
    }

    init(language: String, name: String, archiveBytes: Int64, sha256: String, md5: String,
         expandedBytes: Int, largestEntryBytes: Int, entryCount: Int, license: String) {
        self.language = language
        self.name = name
        self.archiveBytes = archiveBytes
        self.sha256 = sha256
        self.md5 = md5
        self.expandedBytes = expandedBytes
        self.largestEntryBytes = largestEntryBytes
        self.entryCount = entryCount
        self.license = license
    }
}

public enum VoskModelCatalogue {
    public static var all: [VoskModelDescriptor] { VoskVerifiedModels.records }

    public static func model(language: String) -> VoskModelDescriptor? {
        self.all.first { $0.language == language }
    }

    public static func normalize(_ locale: String) -> String {
        let base = locale.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
        return ["cn": "zh", "ua": "uk", "kz": "kk", "vn": "vi"][base] ?? base
    }

    public static func resolve(selection: String, chatLocale: String?, appLocale: String, installed: Set<String>) -> String? {
        guard selection != "none" else { return nil }
        if selection == "auto" {
            for locale in [chatLocale, appLocale].compactMap({ $0 }) {
                let language = self.normalize(locale)
                if self.model(language: language) != nil, installed.contains(language) { return language }
            }
            return nil
        }
        // Explicit selections never silently change language or use another model.
        return self.model(language: selection) != nil && installed.contains(selection) ? selection : nil
    }
}
