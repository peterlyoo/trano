import Foundation

public enum ManagedAccountPath {
    public static func normalized(_ value: String?, runtimeRoot: URL,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        func identity(_ path: String) -> String {
            guard path.hasPrefix("/") else { return "relative:" + path }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let shim = identity(runtimeRoot.appendingPathComponent("bin").path)
        let initial = value?.isEmpty == false ? value! : "/usr/bin:/bin"
        let candidates = initial.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        return candidates.filter {
            let key = identity($0)
            return key != shim && seen.insert(key).inserted
        }.joined(separator: ":")
    }
}
