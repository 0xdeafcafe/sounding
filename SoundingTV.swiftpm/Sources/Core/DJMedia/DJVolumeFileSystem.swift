import CryptoKit
import Darwin
import Foundation

struct DJVolumeIOError: Error, Equatable, Sendable, CustomStringConvertible {
    var code: Int32
    var operation: String
    var path: String

    var looksLikeRemoval: Bool {
        [EIO, ENXIO, ENODEV, ETIMEDOUT, ESTALE, EPIPE, ENOTCONN].contains(code)
    }

    var description: String {
        "\(operation) \(path): \(String(cString: strerror(code)))"
    }
}

protocol DJExportFileSystem: Sendable {
    func exists(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func fileSize(_ url: URL) -> Int64?
    func list(_ url: URL) throws -> [String]
    func read(_ url: URL) throws -> Data
    func digest(_ url: URL) throws -> Data
    func createDirectory(_ url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func copy(from source: URL, to destination: URL, verify: Bool, onChunk: () throws -> Void) throws -> Int64
    func rename(_ from: URL, to: URL) throws
    func remove(_ url: URL) throws
    func syncFile(_ url: URL) throws
    func syncDirectory(_ url: URL) throws
}

extension DJExportFileSystem {
    func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        if exists(temporary) { try remove(temporary) }
        try write(data, to: temporary)
        try rename(temporary, to: url)
        try syncDirectory(url.deletingLastPathComponent())
    }

    func allFiles(under root: URL) -> [URL] {
        var out: [URL] = []
        func walk(_ directory: URL) {
            for name in (try? list(directory)) ?? [] {
                let child = directory.appending(path: name)
                if isDirectory(child) { walk(child) } else { out.append(child) }
            }
        }
        walk(root)
        return out
    }

    func syncTree(_ root: URL) throws {
        func walk(_ directory: URL) throws {
            for name in try list(directory) {
                let child = directory.appending(path: name)
                if isDirectory(child) {
                    try walk(child)
                } else {
                    try syncFile(child)
                }
            }
            try syncDirectory(directory)
        }
        guard isDirectory(root) else { return }
        try walk(root)
    }
}

struct DJPosixFileSystem: DJExportFileSystem {
    private static let chunk = 1 << 20

    private func fail(_ operation: String, _ url: URL) -> DJVolumeIOError {
        DJVolumeIOError(code: errno, operation: operation, path: url.path)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    func fileSize(_ url: URL) -> Int64? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    func list(_ url: URL) throws -> [String] {
        guard let dir = opendir(url.path) else { throw fail("list", url) }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw fail("open", url) }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw fail("read", url)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func digest(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw fail("open", url) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw fail("read", url)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        return Data(hasher.finalize())
    }

    func createDirectory(_ url: URL) throws {
        var built = url.path.hasPrefix("/") ? "" : "."
        for component in url.pathComponents where component != "/" {
            built += "/" + component
            if mkdir(built, 0o755) != 0, errno != EEXIST { throw fail("mkdir", URL(fileURLWithPath: built)) }
        }
        guard isDirectory(url) else { throw DJVolumeIOError(code: ENOTDIR, operation: "mkdir", path: url.path) }
    }

    private func writeAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int, _ url: URL) throws {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, pointer + offset, count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw fail("write", url)
            }
            offset += written
        }
    }

    private func fullSync(_ fd: Int32, _ url: URL) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        let code = errno
        if [ENOTSUP, ENOTTY, EINVAL, EOPNOTSUPP].contains(code) {
            if fsync(fd) == 0 { return }
            throw fail("fsync", url)
        }
        throw DJVolumeIOError(code: code, operation: "fullsync", path: url.path)
    }

    func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw fail("create", url) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { try writeAll(fd, base, raw.count, url) }
        }
        try fullSync(fd, url)
    }

    func copy(from source: URL, to destination: URL, verify: Bool, onChunk: () throws -> Void) throws -> Int64 {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw fail("open", source) }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else { throw fail("create", destination) }
        var closed = false
        defer { if !closed { close(output) } }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        while true {
            try onChunk()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw fail("read", source)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            try buffer.withUnsafeBytes { try writeAll(output, $0.baseAddress!, count, destination) }
            total += Int64(count)
        }
        try fullSync(output, destination)
        closed = true
        guard close(output) == 0 else { throw fail("close", destination) }
        if verify {
            let expected = Data(hasher.finalize())
            guard try digest(destination) == expected else { throw DJMediaExportError.copyMismatch(destination.lastPathComponent) }
        }
        return total
    }

    func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw fail("rename", from) }
    }

    func remove(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw fail("stat", url)
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            for name in try list(url) { try remove(url.appending(path: name)) }
            guard rmdir(url.path) == 0 || errno == ENOENT else { throw fail("rmdir", url) }
        } else {
            guard unlink(url.path) == 0 || errno == ENOENT else { throw fail("unlink", url) }
        }
    }

    func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw fail("open", url) }
        defer { close(fd) }
        try fullSync(fd, url)
    }

    func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw fail("open", url) }
        defer { close(fd) }
        try fullSync(fd, url)
    }
}

struct DJVolumeInfo: Equatable, Sendable {
    enum Kind: String, Sendable {
        case fat, exfat, hfs, apfs, ntfs, other
    }

    var kind: Kind
    var typeName: String
    var isReadOnly: Bool
    var totalBytes: Int64
    var freeBytes: Int64

    var isDJPlayerFormat: Bool { kind == .fat || kind == .exfat }

    var displayName: String {
        switch kind {
        case .fat:   return "FAT32"
        case .exfat: return "exFAT"
        case .hfs:   return "Mac OS Extended"
        case .apfs:  return "APFS"
        case .ntfs:  return "NTFS"
        case .other: return typeName
        }
    }

    static func inspect(_ url: URL) -> DJVolumeInfo? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let name = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let kind: Kind
        switch name {
        case "msdos": kind = .fat
        case "exfat": kind = .exfat
        case "hfs":   kind = .hfs
        case "apfs":  kind = .apfs
        case "ntfs", "ufsd_NTFS": kind = .ntfs
        default:      kind = .other
        }
        let block = Int64(info.f_bsize)
        return DJVolumeInfo(
            kind: kind,
            typeName: name,
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
            totalBytes: block * Int64(info.f_blocks),
            freeBytes: block * Int64(info.f_bavail)
        )
    }
}
