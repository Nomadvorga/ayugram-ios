import AccountContext
import Foundation
import Postbox
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
        let signals: [Signal<CacheUsageStats, NoError>] = accounts.map { account in
            TelegramEngine(account: account).resources.collectCacheUsageStats()
            |> mapToSignal { result -> Signal<CacheUsageStats, NoError> in
                if case let .result(stats) = result { return .single(stats) }
                return .complete()
            }
            |> take(1)
        }
        let combined: Signal<[CacheUsageStats], NoError> = signals.isEmpty ? .single([]) : combineLatest(signals)
        return combined
        |> map { values in
            var bytes: Int64 = 0
            var tempPaths = Set<String>()
            func append(_ size: Int64) {
                let result = bytes.addingReportingOverflow(max(0, size))
                bytes = result.overflow ? Int64.max : result.partialValue
            }
            for stats in values {
                var mediaSizes: [MediaId: Int64] = [:]
                for categories in stats.media.values {
                    for media in categories.values {
                        for (id, size) in media { mediaSizes[id] = max(mediaSizes[id] ?? 0, size) }
                    }
                }
                for size in mediaSizes.values { append(size) }
                append(stats.otherSize); append(stats.cacheSize)
                // The engine reports shared temp paths in every account snapshot.
                if stats.tempPaths.allSatisfy({ !tempPaths.contains($0) }) { append(stats.tempSize) }
                tempPaths.formUnion(stats.tempPaths)
            }
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = (attributes?[.systemSize] as? NSNumber)?.doubleValue ?? 0
            let free = (attributes?[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            return ExteraPillStorageUsage(cacheBytes: bytes, occupiedFraction: total > 0 ? min(1, max(0.05, (total - free) / total)) : 0.05)
        }
        |> runOn(Queue.concurrentDefaultQueue())
    }
}
