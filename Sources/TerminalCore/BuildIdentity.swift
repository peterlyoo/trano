import Foundation

public struct BuildIdentity: Codable, Equatable, Sendable {
    public static let process = BuildIdentity(info: Bundle.main.infoDictionary ?? [:])
    public let version: String
    public let buildNumber: String
    public let buildID: String
    public var isBundled: Bool { buildID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }

    public init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "development"
        buildNumber = info["CFBundleVersion"] as? String ?? "0"
        buildID = info["TranoBuildID"] as? String ?? "unbundled"
    }

    public init(metadataURL: URL) throws {
        let data = try Data(contentsOf: metadataURL)
        let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
        self.init(info: info)
    }
}

public enum ServiceHandoffAction: Equatable { case keep, replace, manualRestart }

public enum ServiceHandoffPolicy {
    public static func action(expected: BuildIdentity, running: BuildIdentity?, kind: String?) -> ServiceHandoffAction {
        if kind == "cli" { return .keep }
        guard expected.isBundled, let running, running.isBundled, kind == "background" else { return .manualRestart }
        return expected == running ? .keep : .replace
    }
}
