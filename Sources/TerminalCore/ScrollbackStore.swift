import Foundation
import Darwin

public struct ScrollbackMetadata: Codable, Equatable {
    public let paneID: String
    public let byteCount: Int
    public let lineCount: Int
    public let updatedAt: Date
}

public struct ScrollbackStore {
    public static let maximumBytes = 4 * 1024 * 1024
    public static let maximumLines = 10_000
    private static let marker = Data("trano-scrollback-v1\n".utf8)
    public let runtimeRoot: URL
    public init(runtimeRoot: URL) { self.runtimeRoot = runtimeRoot }

    public static func sanitized(_ text: String) -> String {
        var data = Data(text.utf8.suffix(maximumBytes))
        while let first = data.first, first & 0xC0 == 0x80 { data.removeFirst() }
        let valid = String(decoding: data, as: UTF8.self).unicodeScalars.filter {
            $0.value == 10 || $0.value == 9 || ($0.value >= 32 && ($0.value < 127 || $0.value > 159))
        }
        let safe = String(String.UnicodeScalarView(valid))
        return safe.split(separator: "\n", omittingEmptySubsequences: false).suffix(maximumLines).joined(separator: "\n")
    }

    private func identifier(_ paneID: String) throws -> String {
        guard UUID(uuidString: paneID) != nil, !paneID.contains("/") else { throw TerminalError.invalid("Invalid scrollback pane ID") }
        return paneID.lowercased()
    }

    private func directory(create: Bool) throws -> URL? {
        let path = runtimeRoot.appendingPathComponent("scrollback", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: path.path) {
            if !create {
                if (try? manager.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType == .typeSymbolicLink { throw TerminalError.invalid("Invalid scrollback directory") }
                return nil
            }
            _ = try ManagedDirectory.ensure(runtimeRoot, component: "scrollback")
        }
        let attributes = try manager.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw TerminalError.invalid("Scrollback must be an owned directory, not a symlink") }
        let marker = path.appendingPathComponent(".trano-scrollback")
        if !manager.fileExists(atPath: marker.path), create {
            guard try manager.contentsOfDirectory(atPath: path.path).isEmpty else { throw TerminalError.invalid("Refusing unmanaged scrollback directory") }
            try TerminalRuntime.atomicWrite(Self.marker, to: marker)
        }
        let markerAttributes = try manager.attributesOfItem(atPath: marker.path)
        guard markerAttributes[.type] as? FileAttributeType == .typeRegular,
              (markerAttributes[.size] as? NSNumber)?.intValue == Self.marker.count,
              try Data(contentsOf: marker) == Self.marker else { throw TerminalError.invalid("Invalid scrollback ownership marker") }
        return path
    }

    private func locked<T>(_ directory: URL, _ action: () throws -> T) throws -> T {
        let fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot open scrollback lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TerminalError.runtime("Cannot lock scrollback") }
        return try action()
    }

    public func save(paneID: String, text: String) throws {
        let id = try identifier(paneID)
        guard let directory = try directory(create: true) else { return }
        try locked(directory) {
            let text = Self.sanitized(text)
            let metadata = ScrollbackMetadata(paneID: id, byteCount: text.utf8.count,
                                              lineCount: text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count, updatedAt: Date())
            var data = try JSONEncoder().encode(metadata)
            data.append(10)
            data.append(contentsOf: text.utf8)
            try TerminalRuntime.atomicWrite(data, to: directory.appendingPathComponent(id + ".snapshot"))
        }
    }

    private func read(paneID: String, includeContent: Bool) throws -> (ScrollbackMetadata?, String) {
        let id = try identifier(paneID)
        guard let directory = try directory(create: false) else { return (nil, "") }
        return try locked(directory) {
            let fd = Darwin.open(directory.appendingPathComponent(id + ".snapshot").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT { return (nil, "") }
            guard fd >= 0 else { throw TerminalError.invalid("Cannot read scrollback archive") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var stat = Darwin.stat()
            guard fstat(fd, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG, stat.st_uid == getuid(),
                  stat.st_size >= 0, stat.st_size <= Self.maximumBytes + 1024 else { throw TerminalError.invalid("Invalid scrollback archive") }
            let prefix = try handle.read(upToCount: 1024) ?? Data()
            guard let newline = prefix.firstIndex(of: 10) else { throw TerminalError.invalid("Invalid scrollback header") }
            let metadata = try JSONDecoder().decode(ScrollbackMetadata.self, from: prefix.prefix(upTo: newline))
            guard metadata.paneID == id, (0...Self.maximumBytes).contains(metadata.byteCount),
                  (0...Self.maximumLines).contains(metadata.lineCount), newline + 1 + metadata.byteCount == stat.st_size else { throw TerminalError.invalid("Invalid scrollback metadata") }
            guard includeContent else { return (metadata, "") }
            try handle.seek(toOffset: UInt64(newline + 1))
            let content = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard content.count == metadata.byteCount, let text = String(data: content, encoding: .utf8) else { throw TerminalError.invalid("Invalid scrollback payload") }
            return (metadata, Self.sanitized(text))
        }
    }

    public func replay(paneID: String) throws -> String { try read(paneID: paneID, includeContent: true).1 }
    public func metadata(paneID: String) throws -> ScrollbackMetadata? { try read(paneID: paneID, includeContent: false).0 }
    public func remove(paneID: String) throws {
        let id = try identifier(paneID)
        guard let directory = try directory(create: false) else { return }
        try locked(directory) {
            let path = directory.appendingPathComponent(id + ".snapshot").path
            if unlink(path) != 0, errno != ENOENT { throw TerminalError.runtime("Cannot remove scrollback archive") }
        }
    }
    public func removeAll() throws {
        guard let directory = try directory(create: false) else { return }
        try locked(directory) {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".snapshot") {
                let id = String(name.dropLast(".snapshot".count))
                guard UUID(uuidString: id) != nil else { continue }
                if unlink(directory.appendingPathComponent(name).path) != 0, errno != ENOENT { throw TerminalError.runtime("Cannot remove scrollback archive") }
            }
        }
    }
}
