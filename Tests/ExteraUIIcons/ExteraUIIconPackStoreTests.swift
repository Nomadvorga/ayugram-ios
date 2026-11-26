import Foundation
import XCTest

final class ExteraUIIconPackStoreTests: XCTestCase {
    private func preview(_ id: String = "custom.test", name: String = "Test", icons: [String: String] = ["msg_copy": "icons/copy.svg"]) throws -> ExteraUIIconPackImport {
        let metadata = try JSONSerialization.data(withJSONObject: ["packId": id, "packName": name, "icons": icons, "extensionData": ["keep": true]] as [String: Any], options: [.sortedKeys])
        return try ExteraUIIconPackImport.validate(ExteraUIIconArchive.encode([
            "metadata.json": metadata,
            "icons/copy.svg": Data("<svg viewBox='0 0 24 24'><path d='M2 2 L22 2 L12 22 Z' fill='#fff'/></svg>".utf8),
            "unknown/android-only.txt": Data("preserve me".utf8)
        ]))
    }
    private func withStore(_ body: (ExteraUIIconPackStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UIIconTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ExteraUIIconPackStore(root: directory), directory)
    }
    func testStoredAndDeflatedAndroidArchives() throws {
        for data in UIIconArchiveFixtures.valid {
            let files = try ExteraUIIconArchive.decode(data)
            XCTAssertEqual(files["metadata.json"], UIIconArchiveFixtures.metadata)
            XCTAssertEqual(files["icons/copy.svg"], UIIconArchiveFixtures.image)
        }
        for data in UIIconArchiveFixtures.streams {
            let files = try ExteraUIIconArchive.decode(data)
            XCTAssertEqual(files["extra.bin"]?.count, 24000)
        }
    }
    func testIndependentCorruptArchiveFixturesAreRejected() {
        for (name, data) in UIIconArchiveFixtures.invalid {
            XCTAssertThrowsError(try ExteraUIIconArchive.decode(data), name)
        }
    }
    func testArchiveRoundTripPreservesAllFilesAndCRC() throws {
        let preview = try self.preview()
        let encoded = try ExteraUIIconArchive.encode(preview.files)
        XCTAssertEqual(try ExteraUIIconArchive.decode(encoded), preview.files)
        XCTAssertEqual(ExteraUIIconArchive.crc32(Data("123456789".utf8)), 0xcbf43926)
        XCTAssertEqual(ExteraUIIconPackImport.digest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var damaged = encoded
        damaged[45] ^= 1
        XCTAssertThrowsError(try ExteraUIIconArchive.decode(damaged))
    }
    func testVisibilityPriorityUpdateAndRestart() throws {
        try withStore { store, root in
            try store.install(self.preview("custom.a"), enable: true)
            try store.install(self.preview("custom.b"), enable: true)
            XCTAssertEqual(store.snapshot.enabled.map { $0.id }, ["custom.a", "custom.b"])
            try store.setEnabled("custom.a", enabled: false)
            XCTAssertEqual(store.snapshot.hidden.map { $0.id }, ["custom.a"])
            try store.setEnabled("custom.a", enabled: true)
            try store.reorder(["custom.b", "custom.a"], enabled: true)
            try store.install(self.preview("custom.b", name: "Updated"), enable: false)
            XCTAssertEqual(store.snapshot.enabled.map { $0.id }, ["custom.b", "custom.a"])
            XCTAssertEqual(ExteraUIIconPackStore(root: root).snapshot, store.snapshot)
            XCTAssertEqual(store.snapshot.enabled.first?.name, "Updated")
            XCTAssertThrowsError(try store.reorder(["custom.a", "custom.a"], enabled: true))
            try store.delete("custom.b")
            XCTAssertEqual(store.snapshot.enabled.map { $0.id }, ["custom.a"])
        }
    }
    func testEditResetReferenceCountingAndUnknownEntries() throws {
        try withStore { store, _ in
            try store.install(self.preview(icons: ["msg_copy": "icons/copy.svg", "android_unknown": "icons/copy.svg"]), enable: true)
            let original = try XCTUnwrap(store.snapshot.enabled.first)
            try store.edit(original.id, resource: "msg_copy")
            let reset = try XCTUnwrap(store.snapshot.enabled.first)
            XCTAssertNil(reset.icons["msg_copy"])
            XCTAssertNotNil(reset.checksums["icons/copy.svg"])
            try store.edit(original.id, name: "Renamed", author: "Author", version: "2.0", resource: "android_unknown")
            let edited = try XCTUnwrap(store.snapshot.enabled.first)
            XCTAssertNil(edited.checksums["icons/copy.svg"])
            XCTAssertEqual(try store.data(for: original, path: "icons/copy.svg"), try self.preview().files["icons/copy.svg"])
            let exported = try ExteraUIIconArchive.decode(store.export(edited))
            XCTAssertEqual(exported["unknown/android-only.txt"], Data("preserve me".utf8))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported["metadata.json"])) as? [String: Any])
            XCTAssertNotNil(json["extensionData"])
            XCTAssertEqual(json["packName"] as? String, "Renamed")
        }
    }
    func testTamperDoesNotDecodeOrExport() throws {
        try withStore { store, root in
            let preview = try self.preview()
            try store.install(preview, enable: true)
            let path = root.appendingPathComponent("revisions/" + preview.pack.revision + "/icons/copy.svg")
            try Data("tampered".utf8).write(to: path)
            XCTAssertThrowsError(try store.data(for: preview.pack, path: "icons/copy.svg"))
            XCTAssertThrowsError(try store.export(preview.pack))
        }
    }
    func testInvalidImportCannotChangeCatalog() throws {
        try withStore { store, _ in
            try store.install(self.preview(), enable: true)
            let before = store.snapshot
            var files = try self.preview().files
            files["metadata.json"] = Data(#"{"packName":"X","packId":"base.solar"}"#.utf8)
            XCTAssertThrowsError(try ExteraUIIconPackImport.validate(ExteraUIIconArchive.encode(files)))
            XCTAssertEqual(store.snapshot, before)
            XCTAssertThrowsError(try store.edit("custom.test", resource: "../escape", image: Data([1]), fileExtension: "png"))
            XCTAssertEqual(store.snapshot, before)
        }
        for metadata in [#"{"packName":"X","packId":"custom.x","author":3}"#, #"{"packName":"X","packId":"custom.x","schemaVersion":true}"#, #"{"packName":"X","packId":"custom.x","icons":{"msg_copy":5}}"#] {
            XCTAssertThrowsError(try ExteraUIIconPackImport.validate(ExteraUIIconArchive.encode(["metadata.json": Data(metadata.utf8)])))
        }
    }
    func testSVGAndVectorSanitization() throws {
        let valid = Data("<svg viewBox='0 0 24 24'><path style='fill:none;stroke:#fff' d='M0 0L24 24'/></svg>".utf8)
        XCTAssertEqual(try ExteraUIIconVector.parse(valid).children.first?.attributes["stroke"], "#fff")
        for text in ["<svg><script/></svg>", "<svg onload='x()'/>", "<svg><foreignObject/></svg>", "<svg><image href='file:///etc/passwd'/></svg>", "<!DOCTYPE svg [<!ENTITY x 'x'>]><svg>&x;</svg>", "<svg><path style='filter:url(#x)'/></svg>"] {
            XCTAssertThrowsError(try ExteraUIIconVector.parse(Data(text.utf8)), text)
        }
        let vector = Data("<vector xmlns:android='http://schemas.android.com/apk/res/android' android:viewportWidth='24' android:viewportHeight='24'><path android:pathData='M0 0L24 24' android:strokeColor='#80ffffff' android:strokeWidth='2'/></vector>".utf8)
        let converted = try ExteraUIIconVector.svgData(vector)
        let parsed = try ExteraUIIconVector.parse(converted)
        XCTAssertEqual(parsed.children.first?.attributes["fill"], "none")
        XCTAssertEqual(parsed.children.first?.attributes["stroke"], "#ffffff")
        XCTAssertEqual(try XCTUnwrap(Double(parsed.children.first?.attributes["stroke-opacity"] ?? "")), 128.0 / 255, accuracy: 0.00001)
    }
    func testConcurrentCatalogMutationsRemainReadable() throws {
        try withStore { store, root in
            try store.install(self.preview("custom.a"), enable: true)
            let group = DispatchGroup(), queue = DispatchQueue(label: "UIIconStoreStress", attributes: .concurrent)
            let errors = UIIconTestErrors()
            for index in 0 ..< 40 {
                group.enter(); queue.async {
                    defer { group.leave() }
                    do { try store.setEnabled("custom.a", enabled: index % 2 == 0) } catch { errors.append(error) }
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
            XCTAssertEqual(errors.count, 0)
            XCTAssertEqual(store.snapshot.all.count, 1)
            XCTAssertEqual(ExteraUIIconPackStore(root: root).snapshot, store.snapshot)
        }
    }
    func testBackupRestoreIsAtomicAndKeepsVisibilityAndUnknownFiles() throws {
        try withStore { source, _ in
            try source.install(self.preview("custom.a"), enable: true)
            try source.install(self.preview("custom.b"), enable: false)
            let backup = try source.exportBackup()
            XCTAssertLessThanOrEqual(backup.count, ExteraUIIconPackStore.maxBackupBytes)
            let plan = try ExteraUIIconPackStore.prepareBackupRestore(backup)
            try self.withStore { target, _ in
                try target.install(self.preview("custom.old"), enable: true)
                let before = target.snapshot
                XCTAssertThrowsError(try target.restoreBackup(plan, validate: { _ in throw ExteraUIIconError.unsupportedImage }))
                XCTAssertEqual(target.snapshot, before)
                try target.restoreBackup(plan, validate: { preview in
                    for path in preview.pack.icons.values { _ = try ExteraUIIconVector.parse(XCTUnwrap(preview.files[path])) }
                })
                XCTAssertEqual(target.snapshot, source.snapshot)
                XCTAssertEqual(try target.exportBackup(), backup)
            }
        }
        XCTAssertThrowsError(try ExteraUIIconPackStore.prepareBackupRestore(Data(repeating: 0, count: ExteraUIIconPackStore.maxBackupBytes + 1)))
        let wrongType = Data(#"{"schemaVersion":true,"archives":{},"sha256":{},"enabled":[],"hidden":[]}"#.utf8)
        XCTAssertThrowsError(try ExteraUIIconPackStore.prepareBackupRestore(wrongType))
    }
    func testSeparateInstancesDoNotOverwriteEachOther() throws {
        try withStore { first, root in
            let second = ExteraUIIconPackStore(root: root)
            try first.install(self.preview("custom.a"), enable: true)
            try second.install(self.preview("custom.b"), enable: true)
            try first.setEnabled("custom.a", enabled: false)
            XCTAssertEqual(first.snapshot.enabled.map { $0.id }, ["custom.b"])
            XCTAssertEqual(first.snapshot.hidden.map { $0.id }, ["custom.a"])
        }
    }
}

private final class UIIconTestErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Error] = []
    func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; values.append(error) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
