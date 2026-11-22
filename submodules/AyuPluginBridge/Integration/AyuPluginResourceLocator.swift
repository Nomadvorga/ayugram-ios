import Foundation

/// Resource bundles contain data, not executable code. In particular, they may
/// have no Info.plist; requiring Bundle(url:) would reject otherwise valid data.
enum AyuPluginResourceLocator {
    enum Payload: Equatable {
        case pythonHome, sdk, smoke

        var bundleName: String {
            switch self {
            case .pythonHome: return "AyuPythonResources.bundle"
            case .sdk, .smoke: return "AyuPluginSDK.bundle"
            }
        }
        var relativePath: String {
            switch self {
            case .pythonHome: return "python"
            case .sdk: return "Python"
            case .smoke: return "Resources/bridge_smoke.plugin"
            }
        }
        var requiredFiles: [String] {
            switch self {
            case .pythonHome: return ["lib/python3.15/encodings/__init__.py"]
            case .sdk: return ["ayu_bridge.py", "_ayu_inspection.py", "base_plugin.py"]
            case .smoke: return []
            }
        }
    }

    /// Only explicit code-owning bundle roots are searched, never user storage,
    /// recursively discovered directories, or a plugin-controlled Python path.
    static func locate(_ payload: Payload, roots: [URL]) -> URL? {
        for root in roots {
            let parent = root.resolvingSymlinksInPath().standardizedFileURL
            let bundle = parent.appendingPathComponent(payload.bundleName, isDirectory: true)
            let candidate = bundle.appendingPathComponent(payload.relativePath).resolvingSymlinksInPath().standardizedFileURL
            guard candidate.pathComponents.starts(with: bundle.pathComponents),
                  let flags = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
                  (payload == .smoke ? flags.isRegularFile == true : flags.isDirectory == true) else { continue }
            let complete = payload.requiredFiles.allSatisfy { path in
                let file = candidate.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                return file.pathComponents.starts(with: candidate.pathComponents)
                    && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            if complete { return candidate }
        }
        return nil
    }
}
