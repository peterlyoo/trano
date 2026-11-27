import Foundation
import CryptoKit
import CoreFoundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DeveloperTerminalAnchoring: String, Codable, CaseIterable, Sendable { case top, bottom }
public enum DeveloperCursorEffect: String, Codable, CaseIterable, Sendable { case none, warp, comet, blaze }
public enum DeveloperUpdateChannel: String, Codable, CaseIterable, Sendable { case preview, bleedingEdge }
public enum DeveloperInstallationLocation: String, Codable, CaseIterable, Sendable { case bundled, sourceCheckout }

public struct DeveloperPreferences: SettingsPreferences, Sendable {
    public var enabled = false
    public var downloadUpdatesAutomatically: Bool?
    public var installUpdatesAutomatically = false
    public var terminalAnchoring = DeveloperTerminalAnchoring.top
    public var cursorEffect = DeveloperCursorEffect.none
    public var newQuickSwitcher = false
    public var quickLookLinks = false
    public var updateChannel = DeveloperUpdateChannel.preview
    public var installationLocation = DeveloperInstallationLocation.bundled
    public var sourceDirectory = ""
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, downloadUpdatesAutomatically, installUpdatesAutomatically, terminalAnchoring, cursorEffect
        case newQuickSwitcher, quickLookLinks, updateChannel, installationLocation, sourceDirectory
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try box.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        downloadUpdatesAutomatically = try box.decodeIfPresent(Bool.self, forKey: .downloadUpdatesAutomatically)
        installUpdatesAutomatically = try box.decodeIfPresent(Bool.self, forKey: .installUpdatesAutomatically) ?? false
        terminalAnchoring = try box.decodeIfPresent(DeveloperTerminalAnchoring.self, forKey: .terminalAnchoring) ?? .top
        cursorEffect = try box.decodeIfPresent(DeveloperCursorEffect.self, forKey: .cursorEffect) ?? .none
        newQuickSwitcher = try box.decodeIfPresent(Bool.self, forKey: .newQuickSwitcher) ?? false
        quickLookLinks = try box.decodeIfPresent(Bool.self, forKey: .quickLookLinks) ?? false
        updateChannel = try box.decodeIfPresent(DeveloperUpdateChannel.self, forKey: .updateChannel) ?? .preview
        installationLocation = try box.decodeIfPresent(DeveloperInstallationLocation.self, forKey: .installationLocation) ?? .bundled
        sourceDirectory = try box.decodeIfPresent(String.self, forKey: .sourceDirectory) ?? ""
    }

    public func validate() throws {
        guard sourceDirectory.utf8.count <= 4096,
              sourceDirectory.rangeOfCharacter(from: .controlCharacters) == nil,
              sourceDirectory.isEmpty || sourceDirectory.hasPrefix("/") else {
            throw TerminalError.invalid("Choose an absolute source directory without control characters.")
        }
        guard installationLocation != .sourceCheckout || !sourceDirectory.isEmpty else {
            throw TerminalError.invalid("Choose the Trano source checkout.")
        }
    }

    public var effectiveCursorEffect: DeveloperCursorEffect { enabled ? cursorEffect : .none }
    public var effectiveAnchoring: DeveloperTerminalAnchoring { enabled ? terminalAnchoring : .top }
    public var usesNewQuickSwitcher: Bool { enabled && newQuickSwitcher }
    public var previewsLinks: Bool { enabled && quickLookLinks }
}

public final class DeveloperSettingsStore {
    private let sidecar: SecureSettingsSidecar<DeveloperPreferences>
    public init(root: URL) throws { sidecar = try SecureSettingsSidecar(root: root, filename: "developer-settings.json") }
    public func load() throws -> DeveloperPreferences { try sidecar.load() }
    @discardableResult public func merge(baseline: DeveloperPreferences, edited: DeveloperPreferences) throws -> DeveloperPreferences {
        try sidecar.merge(baseline: baseline, edited: edited)
    }
}

public struct DeveloperUpdateReadiness: Equatable, Sendable {
    public let available: Bool
    public let reason: String
    public let automaticDownloads: Bool
    public let immediateInstallation: Bool
    public let channels: Set<String>
    public init(available: Bool, reason: String, automaticDownloads: Bool, immediateInstallation: Bool, channels: Set<String>) {
        self.available = available; self.reason = reason; self.automaticDownloads = automaticDownloads
        self.immediateInstallation = immediateInstallation; self.channels = channels
    }
}

public enum DeveloperUpdatePolicy {
    public static func resolve(_ preferences: DeveloperPreferences, info: [String: Any], inheritedAutomaticDownloads: Bool) -> DeveloperUpdateReadiness {
        do {
            _ = try UpdateConfiguration(info: info)
            return DeveloperUpdateReadiness(available: true, reason: "Signed updates are configured.",
                automaticDownloads: preferences.installUpdatesAutomatically || (preferences.downloadUpdatesAutomatically ?? inheritedAutomaticDownloads),
                immediateInstallation: preferences.installUpdatesAutomatically,
                channels: preferences.updateChannel == .bleedingEdge ? ["bleeding-edge"] : [])
        } catch {
            return DeveloperUpdateReadiness(available: false, reason: error.localizedDescription,
                automaticDownloads: false, immediateInstallation: false, channels: [])
        }
    }
}

public struct DeveloperInstallationMetadata: Equatable, Sendable {
    public let executable: URL
    public let version: String
    public let commit: String?
    public let finalSHA256: String
    public let apiVersion: Int
    public let buildID: String
    public init(executable: URL, version: String, commit: String?, finalSHA256: String, apiVersion: Int, buildID: String) {
        self.executable = executable; self.version = version; self.commit = commit
        self.finalSHA256 = finalSHA256; self.apiVersion = apiVersion; self.buildID = buildID
    }
}

public enum DeveloperInstallationInspector {
    public static func inspect(bundle: URL, expectedAPIVersion: Int = 1) throws -> DeveloperInstallationMetadata {
        guard bundle.isFileURL, bundle.pathExtension == "app" else { throw TerminalError.invalid("Select a Trano application bundle.") }
        let base = bundle.standardizedFileURL
        _ = try checked(base, type: .typeDirectory)
        let infoURL = try descendant("Contents/Info.plist", in: base, type: .typeRegular)
        guard (try infoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 262_144 else {
            throw TerminalError.invalid("The helper metadata is too large.")
        }
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              ["dev.trano.app", "dev.trano.activity"].contains(info["CFBundleIdentifier"] as? String ?? ""),
              info["CFBundleExecutable"] as? String == "TranoApp",
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty, version.utf8.count <= 128,
              version.rangeOfCharacter(from: .controlCharacters) == nil,
              let api = info["TranoAPIVersion"] as? NSNumber, CFGetTypeID(api) != CFBooleanGetTypeID(),
              api.doubleValue == Double(expectedAPIVersion),
              let buildID = info["TranoBuildID"] as? String,
              buildID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw TerminalError.invalid("The helper has missing or incompatible Trano metadata. Rebuild the selected checkout.")
        }
        let commit = info["TranoSourceCommit"] as? String
        if let commit, commit.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) == nil {
            throw TerminalError.invalid("The helper source revision is invalid.")
        }
        let executable = try descendant("Contents/MacOS/TranoApp", in: base, type: .typeRegular)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw TerminalError.invalid("The helper is not executable.") }
        return DeveloperInstallationMetadata(executable: executable, version: version, commit: commit,
            finalSHA256: try hash(executable), apiVersion: expectedAPIVersion, buildID: buildID)
    }

    public static func sourceBundle(directory: URL, expectedAPIVersion: Int = 1) throws -> DeveloperInstallationMetadata {
        guard directory.isFileURL else { throw TerminalError.invalid("Choose a local source directory.") }
        let base = directory.standardizedFileURL
        _ = try checked(base, type: .typeDirectory)
        _ = try descendant("Package.swift", in: base, type: .typeRegular)
        let bundle = try descendant("build/Trano.app/Contents/Helpers/Trano Service.app", in: base, type: .typeDirectory)
        return try inspect(bundle: bundle, expectedAPIVersion: expectedAPIVersion)
    }

    private static func descendant(_ relative: String, in base: URL, type: FileAttributeType) throws -> URL {
        let components = relative.split(separator: "/")
        var current = base
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            _ = try checked(current, type: index == components.count - 1 ? type : .typeDirectory)
        }
        return current
    }

    private static func checked(_ url: URL, type: FileAttributeType) throws -> [FileAttributeKey: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == type else { throw TerminalError.invalid("Helper paths must be regular files and directories without symlinks.") }
        return attributes
    }

    private static func hash(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.invalid("Cannot securely read the helper executable.") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 134_217_728 else { throw TerminalError.invalid("The helper executable is unavailable or too large.") }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var total = 0
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.invalid("Cannot read the helper executable.") }
            if count == 0 { break }
            total += count
            guard total <= 134_217_728 else { throw TerminalError.invalid("The helper changed while reading.") }
            digest.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, total == Int(after.st_size) else {
            throw TerminalError.invalid("The helper changed while reading.")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum QuickLookLinkTarget: Equatable, Sendable {
    case file(URL), web(URL)
    public static func parse(_ text: String, cwd: URL) -> QuickLookLinkTarget? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, value.utf8.count <= 16_384, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
            guard url.user == nil, url.password == nil else { return nil }
            if ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty { return .web(url) }
            guard scheme == "file", url.host == nil || url.host == "" || url.host == "localhost", url.query == nil, url.fragment == nil else { return nil }
            let file = url.standardizedFileURL
            return FileManager.default.fileExists(atPath: file.path) ? .file(file) : nil
        }
        guard cwd.isFileURL else { return nil }
        let file = value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL : cwd.appendingPathComponent(value).standardizedFileURL
        return FileManager.default.fileExists(atPath: file.path) ? .file(file) : nil
    }
}

public enum DeveloperQuickSwitcherKind: String, Sendable { case workspace, tab, pane, process }
public struct DeveloperQuickSwitcherEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let kind: DeveloperQuickSwitcherKind
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String?
    public init(id: String, title: String, detail: String, kind: DeveloperQuickSwitcherKind, workspaceID: String?, tabID: String?, paneID: String?) {
        self.id = id; self.title = title; self.detail = detail; self.kind = kind
        self.workspaceID = workspaceID; self.tabID = tabID; self.paneID = paneID
    }
}

public enum DeveloperQuickSwitcher {
    public static func entries(layout: WorkspaceLayout, sessions: [TerminalSession], query: String) -> [DeveloperQuickSwitcherEntry] {
        let open = layout.workspaces.filter { !$0.closed }
        let openIDs = Set(open.map(\.id))
        let tabs = layout.tabs.filter { $0.workspaceID.map(openIDs.contains) == true }
        var entries = open.map { workspace in
            DeveloperQuickSwitcherEntry(id: "workspace:" + workspace.id, title: workspace.title, detail: "Workspace", kind: .workspace, workspaceID: workspace.id, tabID: nil, paneID: nil)
        }
        for tab in tabs {
            let workspace = open.first { $0.id == tab.workspaceID }?.title ?? ""
            entries.append(DeveloperQuickSwitcherEntry(id: "tab:" + tab.id, title: tab.title, detail: workspace + " · Tab", kind: .tab, workspaceID: tab.workspaceID, tabID: tab.id, paneID: nil))
            for paneID in tab.panes {
                guard let session = sessions.first(where: { $0.id == paneID && $0.alive }) else { continue }
                entries.append(DeveloperQuickSwitcherEntry(id: "pane:" + paneID, title: session.displayTitle,
                    detail: workspace + " · " + session.displayProgram.displayName, kind: .pane, workspaceID: tab.workspaceID, tabID: tab.id, paneID: paneID))
                for task in session.agentTasks ?? [] {
                    entries.append(DeveloperQuickSwitcherEntry(id: "process:" + paneID + ":" + task.id, title: task.name,
                        detail: workspace + " · " + task.agent.rawValue + " · " + task.activity.state.rawValue,
                        kind: .process, workspaceID: tab.workspaceID, tabID: tab.id, paneID: paneID))
                }
            }
        }
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return entries }
        return entries.filter { ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(name) }
    }
}

public enum TerminalAnchoringLayout {
    public static func frame(bounds: CGRect, rowHeight: CGFloat, anchoring: DeveloperTerminalAnchoring, flipped: Bool) -> CGRect {
        guard anchoring == .bottom else { return bounds }
        guard rowHeight.isFinite, rowHeight > 0, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 0, bounds.height >= rowHeight else { return bounds }
        let height = floor(bounds.height / rowHeight) * rowHeight
        let startsAtMinimum = (anchoring == .top) == flipped
        return CGRect(x: bounds.minX, y: startsAtMinimum ? bounds.minY : bounds.maxY - height, width: bounds.width, height: height)
    }
}

public struct CursorEffectPoint: Equatable, Sendable {
    public let center: CGPoint
    public let radius: CGFloat
    public let opacity: CGFloat
    public init(center: CGPoint, radius: CGFloat, opacity: CGFloat) { self.center = center; self.radius = radius; self.opacity = opacity }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.center.x == rhs.center.x && lhs.center.y == rhs.center.y && lhs.radius == rhs.radius && lhs.opacity == rhs.opacity
    }
}

public enum CursorEffectGeometry {
    public static func points(style: DeveloperCursorEffect, previous: CGRect, current: CGRect, elapsed: TimeInterval, reduceMotion: Bool) -> [CursorEffectPoint] {
        guard style != .none, !reduceMotion, elapsed.isFinite, elapsed >= 0,
              previous.minX.isFinite, previous.minY.isFinite, current.minX.isFinite, current.minY.isFinite,
              previous.width.isFinite, previous.height.isFinite, current.width.isFinite, current.height.isFinite,
              previous.width > 0, previous.height > 0, current.width > 0, current.height > 0 else { return [] }
        let duration: Double = style == .warp ? 0.14 : 0.2
        guard elapsed < duration else { return [] }
        let dx = current.midX - previous.midX, dy = current.midY - previous.midY
        let distance = hypot(dx, dy)
        guard distance > 0.5 else { return [] }
        let decay = CGFloat(1 - elapsed / duration)
        let base = max(1, min(14, current.height * 0.24))
        let count = style == .comet ? 18 : 12
        return (0..<count).map { index in
            let progress = CGFloat(index + 1) / CGFloat(count + 1)
            let offset = style == .blaze ? sin(progress * .pi * 5) * base * (1 - progress) : 0
            let point = CGPoint(x: previous.midX + dx * progress - dy / distance * offset,
                                y: previous.midY + dy * progress + dx / distance * offset)
            let radius: CGFloat
            switch style {
            case .warp: radius = base * (0.5 + sin(progress * .pi) * 0.7) * decay
            case .comet: radius = base * (0.25 + progress * 0.8) * decay
            case .blaze: radius = base * (0.4 + progress * 0.65) * decay
            case .none: radius = 0
            }
            return CursorEffectPoint(center: point, radius: max(0.1, radius), opacity: min(1, decay * (0.15 + progress * 0.65)))
        }
    }
}
