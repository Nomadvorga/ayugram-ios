import CoreFoundation
import Foundation

/// The main settings backup carries built-in presentation only. HTTP specs and account-scoped
/// provider permissions remain local; their independent transfer format is deliberately excluded.
public enum ExteraPillPortableSettings {
    public static let key = ExteraPillStackSettings.key

    /// Preserve built-in order and visibility, remove installation-specific ids, and repair only
    /// the local projection. Imported documents are validated strictly and are never repaired.
    public static func projection(_ layout: ExteraPillStackLayout) -> ExteraPillStackLayout {
        var result = layout.normalized(custom: [])
        if result.selected == nil { result.selected = result.visible.first }
        return result
    }

    /// Encoding this closed inventory cannot fail: ids come from the built-in enum, not endpoints.
    public static func configurationJSON(_ layout: ExteraPillStackLayout) -> String {
        do {
            return String(decoding: try ExteraPillStackDocument.encode(Self.projection(layout), custom: []), as: UTF8.self)
        } catch {
            preconditionFailure("Built-in Pill projection must encode: \(error)")
        }
    }

    /// The caller supplies the main backup's UTF-8/grammar/duplicate-key validator. It must run on
    /// the inner JSON string before Foundation loses duplicate keys, including escaped aliases.
    public static func decode(_ json: String, rejectDuplicateKeys: (Data) throws -> Void) throws -> ExteraPillStackLayout {
        let data = Data(json.utf8)
        guard data.count <= ExteraPillStackDocument.maximumFileSize else { throw ExteraPillError.invalidFile }
        try rejectDuplicateKeys(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.stringValue == "1",
              let layout = object["layout"] as? [String: Any],
              let infinite = layout["infiniteScrolling"] as? NSNumber, CFGetTypeID(infinite) == CFBooleanGetTypeID() else {
            throw ExteraPillError.invalidFile
        }
        // This rejects unknown root/layout fields, incomplete or duplicate inventories, unknown
        // built-ins, custom references and a selected id outside the visible partition.
        return try ExteraPillStackDocument.decode(data, custom: [])
    }

    /// Only pass a layout returned by decode. The existing setter normalizes against the current
    /// HTTP inventory; retained custom specs are appended hidden and no account grant is touched.
    public static func applyValidated(_ layout: ExteraPillStackLayout, settings: ExteraPillStackSettings, custom: [ExteraPillSpec]) {
        settings.update(custom: custom) { $0 = layout }
    }
}
