import Foundation

public struct UpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String
    public let buildVersion: String

    public init(info: [String: Any]) throws {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw UpdateConfigurationError.invalidFeed
        }
        guard let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.contains(where: { $0 != 0 }) else {
            throw UpdateConfigurationError.invalidPublicKey
        }
        guard let version = info["CFBundleVersion"] as? String,
              version.range(of: #"^[1-9][0-9]*(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil else {
            throw UpdateConfigurationError.invalidVersion
        }
        guard info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            throw UpdateConfigurationError.unsignedMetadata
        }
        feedURL = url
        publicKey = key
        buildVersion = version
    }
}

public enum UpdateConfigurationError: LocalizedError {
    case invalidFeed, invalidPublicKey, invalidVersion, unsignedMetadata

    public var errorDescription: String? {
        switch self {
        case .invalidFeed: return "This build has no valid HTTPS update feed."
        case .invalidPublicKey: return "This build has no valid update signing key."
        case .invalidVersion: return "This build has no valid release version."
        case .unsignedMetadata: return "This build does not require signed update metadata."
        }
    }
}

public enum UpdateLaunchPolicy {
    public static func shouldStart(arguments: [String], bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "dev.trano.app" && !arguments.contains("--service") && !arguments.contains("--snapshot")
    }
}
