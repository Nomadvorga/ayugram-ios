import Foundation

// MARK: AyuGram
// exteraGram's supporter and developer profiles: kept on disk, refreshed from the service every ten minutes
// while badges are switched on and something asks for one.
public final class AyuExteraProfilesStore {
    public static let shared = AyuExteraProfilesStore()
    public static let didChangeNotification = Notification.Name("AyuExteraProfilesDidChange")

    private static let watermarkKey = "extera.profiles.watermark"
    private static let etagKey = "extera.profiles.etag"
    private static let syncTimeKey = "extera.profiles.syncTime"
    private static let failureTimeKey = "extera.profiles.failureTime"

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.ayugram.exteraProfiles", qos: .utility)
    private let session = URLSession(configuration: .ephemeral)
    private let defaults = UserDefaults.standard
    private var table = AyuExteraProfilesTable()
    private var isLoaded = false
    private var isLoading = false
    private var isSyncing = false
    private var lastDueCheck: Double = 0.0

    private init() {
    }

    private var fileURL: URL? {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ayu-extera-profiles.json")
    }

    // The profile of a user or a chat, by the id exteraGram for Android uses (no namespace prefix). Nil while
    // badges are switched off or the saved profiles are still being read.
    public func profile(id: Int64, isUser: Bool) -> AyuExteraProfile? {
        guard ExteraSettings.shared.value(.showExteraBadges) else {
            return nil
        }
        self.lock.lock()
        let profile = self.table.profile(id: id, isUser: isUser)
        let isLoaded = self.isLoaded
        let now = Date().timeIntervalSince1970
        // The state is looked at no more than once in ten seconds.
        let checksDue = now - self.lastDueCheck >= 10.0 || now < self.lastDueCheck
        if checksDue {
            self.lastDueCheck = now
        }
        self.lock.unlock()

        if !isLoaded {
            self.load()
        } else if checksDue {
            self.synchronizeIfDue()
        }
        return profile
    }

    private var state: AyuExteraProfilesSyncState {
        get {
            return AyuExteraProfilesSyncState(
                watermark: self.defaults.string(forKey: AyuExteraProfilesStore.watermarkKey),
                etag: self.defaults.string(forKey: AyuExteraProfilesStore.etagKey),
                lastSyncTime: self.defaults.double(forKey: AyuExteraProfilesStore.syncTimeKey),
                lastFailureTime: self.defaults.double(forKey: AyuExteraProfilesStore.failureTimeKey)
            )
        }
        set {
            self.defaults.set(newValue.watermark, forKey: AyuExteraProfilesStore.watermarkKey)
            self.defaults.set(newValue.etag, forKey: AyuExteraProfilesStore.etagKey)
            self.defaults.set(newValue.lastSyncTime, forKey: AyuExteraProfilesStore.syncTimeKey)
            self.defaults.set(newValue.lastFailureTime, forKey: AyuExteraProfilesStore.failureTimeKey)
        }
    }

    private func load() {
        self.lock.lock()
        if self.isLoaded || self.isLoading {
            self.lock.unlock()
            return
        }
        self.isLoading = true
        self.lock.unlock()

        self.queue.async {
            var table = AyuExteraProfilesTable()
            var hasFile = false
            if let fileURL = self.fileURL, let data = try? Data(contentsOf: fileURL) {
                hasFile = table.apply(response: data)
            }
            if !hasFile {
                // The system may have emptied the caches: everything is asked for again.
                self.state = AyuExteraProfilesSyncState()
            }
            self.lock.lock()
            self.table = table
            self.isLoaded = true
            self.isLoading = false
            self.lock.unlock()
            if table.count != 0 {
                self.notifyChanged()
            }
            self.synchronizeIfDue()
        }
    }

    public func synchronizeIfDue() {
        self.queue.async {
            self.lock.lock()
            let isLoaded = self.isLoaded
            self.lock.unlock()
            guard ExteraSettings.shared.value(.showExteraBadges), isLoaded, !self.isSyncing else {
                return
            }
            let state = self.state
            guard state.isDue(now: Date().timeIntervalSince1970) else {
                return
            }
            self.isSyncing = true
            let wasFull = state.watermark == nil
            self.session.dataTask(with: state.request(), completionHandler: { data, response, _ in
                self.queue.async {
                    self.isSyncing = false
                    let now = Date().timeIntervalSince1970
                    var state = self.state
                    guard let response = response as? HTTPURLResponse else {
                        state.lastFailureTime = now
                        self.state = state
                        return
                    }
                    var table = wasFull ? AyuExteraProfilesTable() : self.currentTable()
                    var stored = true
                    if (200 ..< 300).contains(response.statusCode) {
                        stored = table.apply(response: data ?? Data())
                        if stored, let fileURL = self.fileURL {
                            stored = (try? table.data().write(to: fileURL, options: .atomic)) != nil
                        }
                    }
                    let outcome = state.record(statusCode: response.statusCode, etag: response.value(forHTTPHeaderField: "ETag"), syncTimestamp: response.value(forHTTPHeaderField: "X-Sync-Timestamp"), now: now, stored: stored)
                    self.state = state
                    if outcome == .profiles, table != self.currentTable() {
                        self.lock.lock()
                        self.table = table
                        self.lock.unlock()
                        self.notifyChanged()
                    }
                }
            }).resume()
        }
    }

    private func currentTable() -> AyuExteraProfilesTable {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.table
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AyuExteraProfilesStore.didChangeNotification, object: nil)
        }
    }
}

private extension HTTPURLResponse {
    func value(forHTTPHeaderField field: String) -> String? {
        for (key, value) in self.allHeaderFields {
            if let key = key as? String, key.caseInsensitiveCompare(field) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }
}
