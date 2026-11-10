import Foundation

public enum ShellQuote {
    public static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public struct AttachmentStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func savePNG(_ data: Data) throws -> URL {
        guard (8...(20 * 1024 * 1024)).contains(data.count), data.prefix(8) == Data([137,80,78,71,13,10,26,10]) else {
            throw TerminalError.invalid("Image must be PNG and no larger than 20 MiB")
        }
        let folder = root.appendingPathComponent("attachments")
        if FileManager.default.fileExists(atPath: folder.path) {
            let type = try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw TerminalError.invalid("Attachment directory cannot be a symlink") }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString.lowercased() + ".png")
        try TerminalRuntime.atomicWrite(data, to: file)
        return file
    }
}
