import Foundation
import Speech

@available(iOS 26.0, macOS 26.0, *)
extension ExteraSpeechModelManager {
    public static let shared = ExteraSpeechModelManager(inventory: AppleSpeechAssetInventory())
}

@available(iOS 26.0, macOS 26.0, *)
private struct AppleSpeechAssetInventory: ExteraSpeechAssetInventory {
    func supportedLocales() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.map { $0.identifier }
    }

    func reservedLocales() async -> [String] {
        var identifiers = Set<String>()
        for locale in await AssetInventory.reservedLocales {
            // Apple's reservation may use a variant of the supplied module locale.
            let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            identifiers.insert((canonical ?? locale).identifier)
        }
        return identifiers.sorted()
    }

    func status(localeIdentifier: String) async -> ExteraSpeechModelStatus {
        guard SpeechTranscriber.isAvailable else { return .unsupported }
        let module = SpeechTranscriber(locale: Locale(identifier: localeIdentifier), preset: .transcription)
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: return .unsupported
        case .supported: return .notInstalled
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    func reserve(localeIdentifier: String) async throws {
        try await AssetInventory.reserve(locale: Locale(identifier: localeIdentifier))
    }

    func install(localeIdentifier: String) async throws {
        let module = SpeechTranscriber(locale: Locale(identifier: localeIdentifier), preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try Task.checkCancellation()
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
            }, onCancel: {
                request.progress.cancel()
            })
        }
    }

    func release(localeIdentifier: String) async {
        for locale in await AssetInventory.reservedLocales {
            let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            if ExteraSpeechLocalePolicy.normalized((canonical ?? locale).identifier) == ExteraSpeechLocalePolicy.normalized(localeIdentifier) {
                await AssetInventory.release(reservedLocale: locale)
            }
        }
    }
}
