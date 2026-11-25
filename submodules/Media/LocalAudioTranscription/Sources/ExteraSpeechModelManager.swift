import Foundation

public enum ExteraSpeechModelStatus: Equatable, Sendable {
    case unsupported
    case notInstalled
    case downloading
    case installed
}

public struct ExteraSpeechModel: Equatable, Sendable {
    public let localeIdentifier: String
    public let status: ExteraSpeechModelStatus
    public let isReserved: Bool
}

public enum ExteraSpeechModelError: Error {
    case unavailable
    case unsupportedLocale
    case busy
    case notInstalled
    case releaseFailed
    case installationFailed
}

/// Injectable public-API adapter. Foundation tests run the same management operations
/// against an in-memory inventory; production uses AppleSpeechAssetInventory.
protocol ExteraSpeechAssetInventory: Sendable {
    func supportedLocales() async -> [String]
    func reservedLocales() async -> [String]
    func status(localeIdentifier: String) async -> ExteraSpeechModelStatus
    func reserve(localeIdentifier: String) async throws
    func install(localeIdentifier: String) async throws
    func release(localeIdentifier: String) async
}

/// Release removes this app's real reservation; iOS reclaims shared files later.
/// No local flag is presented as proof of installation/deletion.
public actor ExteraSpeechModelManager {
    private let inventory: any ExteraSpeechAssetInventory
    private var access = ExteraSpeechModelAccess()

    init(inventory: any ExteraSpeechAssetInventory) { self.inventory = inventory }

    public func catalogue() async -> [ExteraSpeechModel] {
        let locales = await self.inventory.supportedLocales()
        let reservations = await self.inventory.reservedLocales()
        var result: [ExteraSpeechModel] = []
        // Keep old reservations releasable if an OS update stops supporting a locale.
        for locale in Set(locales + reservations).sorted() {
            if Task.isCancelled { break }
            let status = await self.inventory.status(localeIdentifier: locale)
            result.append(ExteraSpeechModel(localeIdentifier: locale, status: status,
                isReserved: reservations.contains(where: { Self.sameLocale($0, locale) })))
        }
        return result
    }

    /// The sole download entry point. UI calls it only after an explicit Download action.
    public func install(localeIdentifier: String) async throws {
        guard self.access.beginMaintenance() else { throw ExteraSpeechModelError.busy }
        defer { self.access.endMaintenance() }
        let locale = try await self.supportedLocale(localeIdentifier)
        try Task.checkCancellation()
        let wasReserved = await self.inventory.reservedLocales().contains(where: { Self.sameLocale($0, locale) })
        do {
            try await self.inventory.reserve(localeIdentifier: locale)
            try Task.checkCancellation()
            if await self.inventory.status(localeIdentifier: locale) != .installed {
                try await self.inventory.install(localeIdentifier: locale)
            }
            try Task.checkCancellation()
            guard await self.inventory.status(localeIdentifier: locale) == .installed else {
                throw ExteraSpeechModelError.installationFailed
            }
            guard await self.inventory.reservedLocales().contains(where: { Self.sameLocale($0, locale) }) else {
                throw ExteraSpeechModelError.installationFailed
            }
        } catch {
            // A cancelled/failed first install must not consume a locale reservation.
            if !wasReserved {
                await self.inventory.release(localeIdentifier: locale)
                let remaining = await self.inventory.reservedLocales()
                guard !remaining.contains(where: { Self.sameLocale($0, locale) }) else {
                    throw ExteraSpeechModelError.releaseFailed
                }
            }
            throw error
        }
    }

    /// Selection validates an existing model; it never calls reserve or install.
    public func verifyInstalledModel(localeIdentifier: String) async throws {
        let (lease, _) = try await self.acquire(localeIdentifier: localeIdentifier)
        self.relinquish(lease)
    }

    public func release(localeIdentifier: String) async throws {
        guard self.access.beginMaintenance() else { throw ExteraSpeechModelError.busy }
        defer { self.access.endMaintenance() }
        // Use the actual reservation identifier, including any system-selected variant.
        let reservations = await self.inventory.reservedLocales()
        guard let locale = reservations.first(where: { Self.sameLocale($0, localeIdentifier) }) else { return }
        await self.inventory.release(localeIdentifier: locale)
        let remaining = await self.inventory.reservedLocales()
        guard !remaining.contains(where: { Self.sameLocale($0, locale) }) else { throw ExteraSpeechModelError.releaseFailed }
    }

    /// Acquires an already-installed asset for recognition, without reserving/downloading it.
    func acquire(localeIdentifier: String) async throws -> (UUID, String) {
        guard let lease = self.access.beginRecognition() else { throw ExteraSpeechModelError.busy }
        do {
            let locale = try await self.supportedLocale(localeIdentifier)
            let reservations = await self.inventory.reservedLocales()
            guard reservations.contains(where: { Self.sameLocale($0, locale) }),
                  await self.inventory.status(localeIdentifier: locale) == .installed else { throw ExteraSpeechModelError.notInstalled }
            try Task.checkCancellation()
            return (lease, locale)
        } catch {
            self.access.endRecognition(lease)
            throw error
        }
    }

    func relinquish(_ lease: UUID) { self.access.endRecognition(lease) }

    private func supportedLocale(_ identifier: String) async throws -> String {
        let supported = await self.inventory.supportedLocales()
        guard !supported.isEmpty else { throw ExteraSpeechModelError.unavailable }
        guard let locale = supported.first(where: { Self.sameLocale($0, identifier) }) else { throw ExteraSpeechModelError.unsupportedLocale }
        return locale
    }

    private static func sameLocale(_ lhs: String, _ rhs: String) -> Bool {
        return ExteraSpeechLocalePolicy.normalized(lhs) == ExteraSpeechLocalePolicy.normalized(rhs)
    }
}
