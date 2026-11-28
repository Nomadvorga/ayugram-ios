// Host check of exteraGram's profiles table and synchronization state. Run from the repository root:
// swiftc -warnings-as-errors -o /tmp/ayu-profiles-tests AyuGram/SGSimpleSettings/Sources/AyuExteraProfilesCore.swift AyuGram/SGSimpleSettings/Tests/main.swift && /tmp/ayu-profiles-tests
// With the argument "live" it also asks the service for the profiles and the changes.

import Foundation

var passed = 0
var failed = 0
func check(_ label: String, _ expected: String, _ actual: String) {
    if expected == actual {
        passed += 1
    } else {
        failed += 1
        print("FAILED \(label): expected \(expected), got \(actual)")
    }
}

var table = AyuExteraProfilesTable()
check("answer applied", "true 4", "\(table.apply(response: Data(#"""
[{"id":50,"type":"USER","status":"SUPPORTER","badge":{"documentId":5391059537102927631},"number":2273},
 {"id":77,"type":"USER","status":"DEVELOPER","badge":{"documentId":5359407509327085568,"text":"{name} builds things"},"canChangeBadge":true},
 {"id":50,"type":"CHAT","status":"SUPPORTER","badge":{"documentId":11},"number":-1},
 {"id":90,"type":"USER","status":"SOMETHING NEW"},
 {"id":"x","type":"USER"}, {"id":5,"type":"BOT"}, 7]
"""#.utf8))) \(table.count)")
check("users and chats do not share ids", "5391059537102927631 11 nil", "\(table.profile(id: 50, isUser: true)?.badgeDocumentId ?? 0) \(table.profile(id: 50, isUser: false)?.badgeDocumentId ?? 0) \(table.profile(id: 77, isUser: false).map { "\($0.id)" } ?? "nil")")
let developer = table.profile(id: 77, isUser: true)
check("developer", "developer {name} builds things true nil", "\(developer?.status.rawValue.lowercased() ?? "") \(developer?.badgeText ?? "") \(developer?.canChangeBadge ?? false) \(developer?.formattedNumber ?? "nil")")
check("numbers", "#2273 nil nil", "\(table.profile(id: 50, isUser: true)?.formattedNumber ?? "nil") \(table.profile(id: 50, isUser: false)?.formattedNumber ?? "nil") \(table.profile(id: 90, isUser: true)?.formattedNumber ?? "nil")")
check("unknown status is a profile without a badge", "regular nil", "\(table.profile(id: 90, isUser: true)?.status == .regular ? "regular" : "other") \(table.profile(id: 90, isUser: true)?.badgeDocumentId.map { "\($0)" } ?? "nil")")
var restored = AyuExteraProfilesTable()
check("saved table reads back", "true true", "\(restored.apply(response: table.data())) \(restored == table)")
check("changes: deleted dropped, others replaced", "true 3 nil 12", { () -> String in
    let applied = table.apply(response: Data(#"[{"id":50,"type":"USER","status":"SUPPORTER","deleted":true},{"id":50,"type":"CHAT","status":"SUPPORTER","badge":{"documentId":12}}]"#.utf8))
    return "\(applied) \(table.count) \(table.profile(id: 50, isUser: true).map { "\($0.id)" } ?? "nil") \(table.profile(id: 50, isUser: false)?.badgeDocumentId ?? 0)"
}())
check("not an answer", "false false 3", "\(table.apply(response: Data("<html>".utf8))) \(table.apply(response: Data(#"{"error":"x"}"#.utf8))) \(table.count)")

var state = AyuExteraProfilesSyncState()
check("first request asks for everything", "https://api.exteragram.app/api/v1/profiles nil true", "\(state.request().url?.absoluteString ?? "") \(state.request().value(forHTTPHeaderField: "If-None-Match") ?? "nil") \(state.isDue(now: 1000.0))")
check("answer recorded", "profiles 2026-11-28T09:34:12.969585404Z \"abc\" false true", "\(state.record(statusCode: 200, etag: "\"abc\"", syncTimestamp: "2026-11-28T09:34:12.969585404Z", now: 1000.0)) \(state.watermark ?? "nil") \(state.etag ?? "nil") \(state.isDue(now: 1599.0)) \(state.isDue(now: 1600.0))")
check("then the changes since", "https://api.exteragram.app/api/v1/profiles/updates?since=2026-11-28T09:34:12.969585404Z \"abc\"", "\(state.request().url?.absoluteString ?? "") \(state.request().value(forHTTPHeaderField: "If-None-Match") ?? "nil")")
check("not modified keeps the tag and moves the time", "unchanged \"abc\" 2026-11-28T09:44:13Z false", "\(state.record(statusCode: 304, etag: nil, syncTimestamp: "2026-11-28T09:44:13Z", now: 1600.0)) \(state.etag ?? "nil") \(state.watermark ?? "nil") \(state.isDue(now: 1700.0))")
check("failure backs off for five minutes", "failed false false true 2026-11-28T09:44:13Z", "\(state.record(statusCode: 503, etag: nil, syncTimestamp: nil, now: 2300.0)) \(state.isDue(now: 2301.0)) \(state.isDue(now: 2599.0)) \(state.isDue(now: 2600.0)) \(state.watermark ?? "nil")")
check("profiles that could not be kept count as a failure", "failed", "\(state.record(statusCode: 200, etag: "\"x\"", syncTimestamp: "2026-11-28T10:00:00Z", now: 2700.0, stored: false))")
check("a missing or broken service time becomes the device's", "1970-01-01T01:00:00Z 1970-01-01T02:00:00Z", { () -> String in
    var state = AyuExteraProfilesSyncState()
    _ = state.record(statusCode: 200, etag: nil, syncTimestamp: nil, now: 3600.0)
    let first = state.watermark ?? "nil"
    _ = state.record(statusCode: 200, etag: nil, syncTimestamp: "yesterday", now: 7200.0)
    return "\(first) \(state.watermark ?? "nil")"
}())
check("clock set back makes a synchronization due", "true", "\(AyuExteraProfilesSyncState(watermark: "x", lastSyncTime: 5000.0).isDue(now: 4000.0))")

if CommandLine.arguments.contains("live") {
    func fetch(_ request: URLRequest) -> (Int, Data, String?, String?) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Data, String?, String?) = (0, Data(), nil, nil)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse {
                result = (response.statusCode, data ?? Data(), response.allHeaderFields["Etag"] as? String, response.allHeaderFields["x-sync-timestamp"] as? String)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30.0)
        return result
    }
    var liveState = AyuExteraProfilesSyncState()
    var liveTable = AyuExteraProfilesTable()
    let full = fetch(liveState.request())
    let stored = liveTable.apply(response: full.1)
    print("live profiles: HTTP \(full.0), applied \(stored), \(liveTable.users.count) users, \(liveTable.chats.count) chats, outcome \(liveState.record(statusCode: full.0, etag: full.2, syncTimestamp: full.3, now: Date().timeIntervalSince1970, stored: stored)), watermark \(liveState.watermark ?? "nil")")
    let changes = fetch(liveState.request())
    print("live changes: HTTP \(changes.0), \(changes.1.count) bytes, url \(liveState.request().url?.absoluteString ?? "")")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
