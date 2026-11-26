import AccountContext
import Foundation
import SGSimpleSettings
import SwiftSignalKit
import TelegramCore

struct ExteraPillStorageUsage {
    let cacheBytes: Int64
    let occupiedFraction: Double
}

/// Aggregate the media/cache of all opened accounts, without walking databases,
/// credentials or document exports. Shared temp paths are counted once.
func exteraPillStorageUsage(context: AccountContext) -> Signal<ExteraPillStorageUsage, NoError> {
    return context.sharedContext.activeAccountsWithInfo
    |> take(1)
    |> mapToSignal { value -> Signal<ExteraPillStorageUsage, NoError> in
        let accounts = value.accounts.map { $0.account }
        let signals: [Signal<EngineCacheUsageSummary, NoError>] = accounts.map { account in
            TelegramEngine(account: account).resources.collectCacheUsageSummary()
            |> take(1)
        }
        let combined: Signal<[EngineCacheUsageSummary], NoError> = signals.isEmpty ? .single([]) : combineLatest(signals)
        return combined
        |> map { values in
            let snapshots = values.map { ExteraPillCacheUsageSnapshot(resourceBytes: $0.resourceBytes, cacheBytes: $0.cacheBytes, temporaryBytes: $0.temporaryBytes) }
            let bytes = ExteraPillCacheAccounting.totalBytes(snapshots)
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = (attributes?[.systemSize] as? NSNumber)?.doubleValue ?? 0
            let free = (attributes?[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            return ExteraPillStorageUsage(cacheBytes: bytes, occupiedFraction: total > 0 ? min(1, max(0.05, (total - free) / total)) : 0.05)
        }
        |> runOn(Queue.concurrentDefaultQueue())
    }
}
