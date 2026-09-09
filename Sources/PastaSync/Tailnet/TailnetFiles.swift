#if os(macOS)
import Foundation
import CryptoKit
import Darwin
import PastaCore

public enum TailnetError: LocalizedError, Sendable {
    case invalid(String), unavailable(String), denied, timeout
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s): return s
        case .denied: return "Pairing or transfer is not authorised."
        case .timeout: return "The other Mac did not respond. Will retry when connected."
        }
    }
}

struct TailnetFile: Codable, Equatable, Sendable {
    var path: String
    var size: Int64
    var sha256: String
}
struct TailnetManifest: Codable, Sendable {
    var entry: ClipboardEntry
    var files: [TailnetFile]
    var directories: [String]
    var roots: [String]
    var changedSinceCapture: Bool
    var backfill: Bool
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var digest: String { get throws { TailnetFiles.hash(try Self.encoder.encode(self)) } }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }

    func validate(limit: Int64) throws {
        guard files.count + directories.count <= 10_000, limit > 0,
              entry.imagePath == nil, entry.rawData == nil, entry.content.utf8.count <= 1_000_000,
              (entry.metadata?.utf8.count ?? 0) <= 1_000_000,
              entry.timestamp.timeIntervalSince1970.isFinite else { throw TailnetError.invalid("Invalid or oversized transfer manifest.") }
        var total: Int64 = 0
        var paths = Set<String>()
        for file in files {
            try Self.validatePath(file.path)
            guard file.size >= 0, file.size <= limit - total,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }),
                  paths.insert(file.path.lowercased()).inserted else { throw TailnetError.invalid("Transfer exceeds the receiver limit or contains duplicate paths.") }
            total += file.size
        }
        for directory in directories {
            try Self.validatePath(directory)
            guard paths.insert(directory.lowercased()).inserted else { throw TailnetError.invalid("Conflicting file and folder paths.") }
        }
        let filePaths = Set(files.map { $0.path.lowercased() })
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !filePaths.contains(parent) else { throw TailnetError.invalid("A file cannot contain another path.") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        if entry.contentType == .filePath {
            guard !roots.isEmpty, roots.count <= 1000, entry.content.isEmpty else { throw TailnetError.invalid("Invalid file selection.") }
            for root in roots {
                try Self.validatePath(root)
                guard paths.contains(root.lowercased()) else { throw TailnetError.invalid("Missing selected file.") }
            }
        } else {
            guard roots.isEmpty, directories.isEmpty, files.count <= 1,
                  files.allSatisfy({ $0.path == "data" && $0.size <= 64_000_000 }) else { throw TailnetError.invalid("Invalid clipboard attachment.") }
        }
    }
    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, parts.count <= 64,
              !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw TailnetError.invalid("Unsafe or unsupported filename.")
        }
    }
}

struct TailnetPrepared: Sendable {
    var manifest: TailnetManifest
    var sources: [URL]
    var temporary: URL?
    func cleanup() { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
}

/// Only regular files/directories, no archive extraction and no executable launch.
struct TailnetFiles: Sendable {
    static let chunkSize = 256 * 1024
    // Matches the largest configurable receiver quota. Sender snapshots also
    // preserve the same free-space reserve used by incoming transfers.
    static let maximumSelectionBytes: Int64 = 1_000_000_000_000
    let root: URL
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: chunkSize), !bytes.isEmpty {
            try Task.checkCancellation(); hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func prepare(_ original: ClipboardEntry, backfill: Bool) throws -> TailnetPrepared {
        var entry = original
        entry.imagePath = nil; entry.rawData = nil; entry.isPinned = false
        entry.cloudSyncAllowed = false; entry.receivedViaTailnet = true
        var result = TailnetPrepared(manifest: TailnetManifest(entry: entry, files: [], directories: [], roots: [], changedSinceCapture: false, backfill: backfill), sources: [])
        do {
            if original.contentType == .filePath {
                result.manifest.entry.content = ""
                guard !original.filePaths.isEmpty, original.filePaths.count <= 1000 else { throw TailnetError.invalid("Empty or oversized file selection.") }
                let temporary = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
                result.temporary = temporary
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                for (index, path) in original.filePaths.enumerated() {
                    guard path.hasPrefix("/") else { throw TailnetError.invalid("A file selection must use absolute local paths.") }
                    let source = URL(fileURLWithPath: path)
                    let relative = "\(index)/\(source.lastPathComponent)"
                    result.manifest.roots.append(relative)
                    let descriptor = try openSource(path, parent: AT_FDCWD)
                    defer { Darwin.close(descriptor) }
                    try append(descriptor, relative: relative, captured: original.timestamp, result: &result)
                }
            } else if let bytes = original.rawData {
                guard bytes.count <= 64_000_000 else { throw TailnetError.invalid("Clipboard attachment exceeds 64 MB.") }
                let temporary = root.appendingPathComponent("out-\(UUID().uuidString)")
                result.temporary = temporary
                try bytes.write(to: temporary, options: .atomic)
                result.sources = [temporary]
                result.manifest.files = [TailnetFile(path: "data", size: Int64(bytes.count), sha256: Self.hash(bytes))]
            } else if (original.contentType == .image || original.contentType == .screenshot), let path = original.imagePath {
                let url = URL(fileURLWithPath: path)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 64_000_000 else { throw TailnetError.invalid("Clipboard image exceeds 64 MB.") }
                result.sources = [url]
                result.manifest.files = [TailnetFile(path: "data", size: Int64(size), sha256: try Self.hashFile(url))]
            }
            try result.manifest.validate(limit: Int64.max)
            return result
        } catch { result.cleanup(); throw error }
    }
    private func openSource(_ path: String, parent: Int32) throws -> Int32 {
        // Every descendant is opened relative to a held directory descriptor.
        // A rename cannot redirect traversal, and O_NONBLOCK prevents a swapped
        // FIFO from hanging before fstat rejects it.
        let descriptor = Darwin.openat(parent, path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw TailnetError.unavailable("Source unavailable or a symbolic link. Restore the original file or folder, then Retry.")
        }
        return descriptor
    }
    private func children(of descriptor: Int32) throws -> [String] {
        let copy = Darwin.dup(descriptor)
        guard copy >= 0 else { throw TailnetError.unavailable("Could not read the source folder. Retry.") }
        guard let directory = fdopendir(copy) else {
            Darwin.close(copy)
            throw TailnetError.unavailable("Could not read the source folder. Retry.")
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw TailnetError.unavailable("Could not read the complete source folder. Retry.") }
                break
            }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < 10_000 else { throw TailnetError.invalid("Selection exceeds 10,000 files/folders.") }
            names.append(name)
        }
        return names.sorted()
    }
    private func append(_ descriptor: Int32, relative: String, captured: Date, result: inout TailnetPrepared) throws {
        try Task.checkCancellation()
        try TailnetManifest.validatePath(relative)
        guard result.manifest.files.count + result.manifest.directories.count < 10_000 else { throw TailnetError.invalid("Selection exceeds 10,000 files/folders.") }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw TailnetError.unavailable("Could not inspect the source. Retry.") }
        let modified = Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1_000_000_000)
        if modified > captured { result.manifest.changedSinceCapture = true }
        if before.st_mode & S_IFMT == S_IFDIR {
            result.manifest.directories.append(relative)
            for name in try children(of: descriptor) {
                let child = try openSource(name, parent: descriptor)
                defer { Darwin.close(child) }
                try append(child, relative: relative + "/" + name, captured: captured, result: &result)
            }
        } else if before.st_mode & S_IFMT == S_IFREG {
            let size = Int64(before.st_size)
            guard size >= 0, size <= Self.maximumSelectionBytes - result.manifest.totalBytes else {
                throw TailnetError.invalid("Selection exceeds the maximum 1 TB transfer size.")
            }
            let free = (try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard size <= max(0, free - 64_000_000) else {
                throw TailnetError.unavailable("Not enough free space to prepare this selection. Free space, then retry.")
            }
            let snapshot = result.temporary!.appendingPathComponent(String(result.sources.count))
            guard FileManager.default.createFile(atPath: snapshot.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: snapshot); defer { try? output.close() }
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            var remaining = size
            var hash = SHA256()
            while remaining > 0 {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: Int(min(Int64(Self.chunkSize), remaining))), !bytes.isEmpty else {
                    throw TailnetError.invalid("Source changed while preparing. Retry to send its current contents.")
                }
                try output.write(contentsOf: bytes)
                hash.update(data: bytes); remaining -= Int64(bytes.count)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
                throw TailnetError.invalid("Source changed while preparing. Retry to send its current contents.")
            }
            // Hash the bytes written to private staging, then send only those
            // snapshots. Approval can never authorise a later source mutation.
            result.manifest.files.append(TailnetFile(path: relative, size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
            result.sources.append(snapshot)
        } else { throw TailnetError.invalid("Only regular files and folders can be transferred.") }
    }

    func staging(_ id: UUID) -> URL { root.appendingPathComponent("part-" + id.uuidString, isDirectory: true) }
    func final(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func begin(_ manifest: TailnetManifest, limit: Int64) throws -> [Int64] {
        try manifest.validate(limit: limit)
        let bytes = try TailnetManifest.encoder.encode(manifest)
        let committed = final(manifest.entry.id)
        let recovery = committed.appendingPathComponent("manifest.json")
        // Retain a completed payload through a crash between filesystem rename
        // and SQLite receipt commit. A retry can acknowledge it without rereading
        // already delivered bytes from a now-missing original.
        if (try? Data(contentsOf: recovery)) == bytes {
            return manifest.files.map(\.size)
        }
        let folder = staging(manifest.entry.id)
        let marker = folder.appendingPathComponent("manifest.json")
        if (try? Data(contentsOf: marker)) != bytes {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("content"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: marker, options: .atomic)
        }
        let content = folder.appendingPathComponent("content")
        for directory in manifest.directories {
            try FileManager.default.createDirectory(at: content.appendingPathComponent(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let offsets: [Int64] = try manifest.files.map { file in
            let url = content.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size <= file.size else { throw TailnetError.invalid("Partial file exceeds expected length. Retry the transfer.") }
            return size
        }
        let remaining = zip(manifest.files, offsets).reduce(Int64(0)) { $0 + $1.0.size - $1.1 }
        let free = (try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard remaining <= max(0, free - 64_000_000) else { throw TailnetError.unavailable("Not enough free space to receive this selection. Free space, then retry.") }
        return offsets
    }
    func appendChunk(_ data: Data, index: Int, offset: Int64, manifest: TailnetManifest) throws {
        guard manifest.files.indices.contains(index), data.count <= Self.chunkSize, !data.isEmpty, offset >= 0 else { throw TailnetError.invalid("Invalid file chunk.") }
        let item = manifest.files[index]
        guard offset <= item.size, Int64(data.count) <= item.size - offset else { throw TailnetError.invalid("File chunk exceeds declared length.") }
        let url = staging(manifest.entry.id).appendingPathComponent("content").appendingPathComponent(item.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        guard try handle.seekToEnd() == UInt64(offset) else { throw TailnetError.invalid("Chunk offset changed; reconnect to resume.") }
        try handle.write(contentsOf: data)
    }
    func finish(_ manifest: TailnetManifest) throws -> ClipboardEntry {
        let stage = staging(manifest.entry.id)
        let destination = final(manifest.entry.id)
        let bytes = try TailnetManifest.encoder.encode(manifest)
        let recovered = (try? Data(contentsOf: destination.appendingPathComponent("manifest.json"))) == bytes
        let content = (recovered ? destination : stage).appendingPathComponent("content")
        for file in manifest.files {
            let url = content.appendingPathComponent(file.path)
            guard Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == file.size,
                  try Self.hashFile(url) == file.sha256 else {
                try? FileManager.default.removeItem(at: recovered ? destination : stage)
                throw TailnetError.invalid("File changed during transfer or failed integrity validation; retry from the sender.")
            }
        }
        var entry = manifest.entry
        if entry.contentType == .filePath {
            if !recovered {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: stage, to: destination)
            }
            let paths = manifest.roots.map { destination.appendingPathComponent("content").appendingPathComponent($0).path }
            entry.content = paths.joined(separator: "\n")
            entry.rawData = try JSONEncoder().encode(paths)
        } else if !manifest.files.isEmpty {
            entry.rawData = try Data(contentsOf: content.appendingPathComponent("data"))
        }
        // Non-file payloads can be retried from staging if SQLite rejects commit.
        return entry
    }
    func acknowledge(_ id: UUID) {
        try? FileManager.default.removeItem(at: staging(id))
    }
    func discardPartial(_ id: UUID) throws {
        let path = staging(id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    /// Only our UUID-owned directories are eligible. Never interpret history paths
    /// as cleanup targets, and never touch arbitrary paths supplied by a peer.
    func cleanup(database: DatabaseManager, active: Set<UUID>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let name = url.lastPathComponent
            if let id = UUID(uuidString: name), !active.contains(id), try database.fetch(id: id) == nil {
                // Deleted history cleans up immediately; an uncommitted rename
                // has no journal identity yet and gets a one-day recovery window.
                let seen = try TailnetStore(database: database).hasReceived(id)
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                if seen || modified < Date().addingTimeInterval(-86_400) { try FileManager.default.removeItem(at: url) }
            } else if name.hasPrefix("part-") || name.hasPrefix("out-") {
                if let id = UUID(uuidString: String(name.dropFirst(5))), active.contains(id) { continue }
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                if modified < Date().addingTimeInterval(-86_400) { try FileManager.default.removeItem(at: url) }
            }
        }
    }
}
#endif
