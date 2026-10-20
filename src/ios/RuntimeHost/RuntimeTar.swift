//
//  RuntimeTar.swift
//  Minis / RuntimeHost
//
//  A ustar reader, extracted from the installer so it can be tested without a
//  device. Foundation only — no Darwin, no UIKit, no CryptoKit — so the same
//  file compiles for iOS *and* as a host-side test binary.
//
//  Scope, stated so nobody assumes more: long names (GNU 'L' and pax 'x'),
//  symlinks, hardlinks, directories, regular files and mode bits. Deliberately
//  not supported: sparse files, device nodes, xattrs. None appear in the
//  runtime payloads; refusing loudly beats writing them wrong.
//
//  Two format details that are easy to get wrong and both appeared in the first
//  draft:
//
//   * A pax record is `LEN key=value\n` — the *length* leads, so a line never
//     begins with `path=`. Matching on the prefix silently drops every long
//     path back to the truncated 100-byte ustar field.
//   * Size fields are NUL- or space-terminated octal, and a value >= 8 GB is
//     stored big-endian with the high bit of the first byte set.
//

import Foundation

enum TarError: Error, LocalizedError {
    case notTar
    case truncated(String)
    case pathEscape(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notTar: return "not a tar archive"
        case .truncated(let where_): return "truncated archive at \(where_)"
        case .pathEscape(let p): return "entry escapes the destination: \(p)"
        case .io(let what): return "I/O failure: \(what)"
        }
    }
}

enum TarEntryKind: String {
    case file = "0"
    case hardlink = "1"
    case symlink = "2"
    case directory = "5"
    case other = "?"
}

struct TarEntry {
    let path: String
    let kind: TarEntryKind
    let mode: Int
    let size: Int
    let linkTarget: String?
}

enum TarReader {

    static let blockSize = 512

    // MARK: - Detection

    /// ustar magic lives at offset 257. Cheap enough to run before extraction.
    static func looksLikeTar(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 265), head.count >= 262 else { return false }
        return Array(head[257..<262]) == Array("ustar".utf8)
    }

    // MARK: - Extraction

    /// Extracts `archive` into `destination` and returns what it wrote, in
    /// archive order. The returned entries are the same data the host-side test
    /// binary asserts against, which is why they carry mode and link target.
    @discardableResult
    static func extract(archive: URL, into destination: URL) throws -> [TarEntry] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archive)
        } catch {
            throw TarError.io("open \(archive.lastPathComponent)")
        }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path)
        let total = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        return try parse(handle: handle, totalSize: total, destination: destination)
    }

    // MARK: - Core

    private static func parse(handle: FileHandle,
                              totalSize: Int,
                              destination: URL) throws -> [TarEntry] {

        let fm = FileManager.default
        var remaining = totalSize
        var entries: [TarEntry] = []

        var pendingLongName: String?
        var pendingPaxPath: String?

        let base = destination.standardizedFileURL.path
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        func readExactly(_ count: Int) -> Data? {
            var out = Data()
            while out.count < count {
                let want = count - out.count
                guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { return nil }
                out.append(chunk)
            }
            return out
        }

        while remaining > 0 {
            guard let headerData = readExactly(blockSize) else { break }
            remaining -= blockSize

            let header = [UInt8](headerData)
            // Two zero blocks end the archive; one is enough to stop reading.
            if header.allSatisfy({ $0 == 0 }) { break }

            func field(_ start: Int, _ length: Int) -> String {
                let end = min(start + length, header.count)
                guard start < end else { return "" }
                let bytes = header[start..<end].prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }

            let name = field(0, 100)
            let modeText = field(100, 8)
            let sizeText = field(124, 12)
            let typeflag = header[156]
            let linkName = field(157, 100)
            let namePrefix = field(345, 155)

            let size = parseSize(sizeText)
            if size < 0 { throw TarError.truncated("negative size for \(name)") }

            // Entry payload, padded to a block boundary.
            let padded = (size + blockSize - 1) / blockSize * blockSize
            var payload: Data?
            if size > 0 {
                guard let body = readExactly(padded) else {
                    throw TarError.truncated("payload of \(name)")
                }
                remaining -= padded
                payload = body.prefix(size)
            }

            // Meta entries: consume and continue without producing a file.
            switch typeflag {
            case UInt8(ascii: "L"):
                pendingLongName = payload
                    .flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                continue
            case UInt8(ascii: "x"):
                if let body = payload.flatMap({ String(data: $0, encoding: .utf8) }) {
                    pendingPaxPath = paxPath(in: body) ?? pendingPaxPath
                }
                continue
            case UInt8(ascii: "g"):
                continue
            default:
                break
            }

            var path = pendingLongName ?? pendingPaxPath
                ?? (namePrefix.isEmpty ? name : "\(namePrefix)/\(name)")
            pendingLongName = nil
            pendingPaxPath = nil
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\0/"))
            if path.isEmpty { continue }

            // Traversal guard. A `../` or a leading `/` in a runtime payload is
            // either a packaging bug or an attack; both must fail here rather
            // than land outside the install root.
            let target = destination.appendingPathComponent(path).standardizedFileURL
            guard target.path == base || target.path.hasPrefix(base + "/") else {
                throw TarError.pathEscape(path)
            }

            let parsedMode = Int(modeText.trimmingCharacters(in: .whitespaces), radix: 8) ?? 0o644
            let mode = parsedMode & 0o7777
            let parent = target.deletingLastPathComponent()

            switch typeflag {
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                entries.append(TarEntry(path: path, kind: .directory,
                                        mode: mode, size: 0, linkTarget: nil))

            case UInt8(ascii: "2"):
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkName)
                entries.append(TarEntry(path: path, kind: .symlink,
                                        mode: mode, size: 0, linkTarget: linkName))

            case UInt8(ascii: "1"):
                let source = destination.appendingPathComponent(linkName).standardizedFileURL
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                if fm.fileExists(atPath: source.path) {
                    try fm.linkItem(at: source, to: target)
                    entries.append(TarEntry(path: path, kind: .hardlink,
                                            mode: mode, size: 0, linkTarget: linkName))
                }

            default:
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                guard let payload else {
                    // A zero-length regular file is legitimate.
                    Data().write(to: target, atomically: true)
                    _ = chmodPath(target.path, mode)
                    entries.append(TarEntry(path: path, kind: .file,
                                            mode: mode, size: 0, linkTarget: nil))
                    continue
                }
                do {
                    try payload.write(to: target, options: .atomic)
                } catch {
                    throw TarError.io("write \(path)")
                }
                _ = chmodPath(target.path, mode)
                entries.append(TarEntry(path: path, kind: .file,
                                        mode: mode, size: size, linkTarget: nil))
            }
        }

        return entries
    }

    // MARK: - Field parsing

    /// Octal, or base-256 when the high bit of the first byte is set.
    static func parseSize(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        if let first = trimmed.utf8.first, first & 0x80 != 0 {
            var value = 0
            for byte in trimmed.utf8.dropFirst() {
                value = (value << 8) | Int(byte)
            }
            return value
        }
        let digits = trimmed.prefix { $0 >= "0" && $0 <= "7" }
        return Int(digits, radix: 8) ?? 0
    }

    /// Pulls `path` out of a pax extended header.
    ///
    /// Records are `LEN key=value\n` where LEN includes itself. The length is
    /// leading, so the line starts with digits — not with `path=`. Splitting on
    /// the first space and then on `=` is the smallest correct handling.
    static func paxPath(in body: String) -> String? {
        for record in body.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let rest = record[record.index(after: space)...]
            guard let equals = rest.firstIndex(of: "=") else { continue }
            if rest[rest.startIndex..<equals] == "path" {
                return String(rest[rest.index(after: equals)...])
            }
        }
        return nil
    }

    /// chmod without importing Darwin: `FileManager.setAttributes` is portable.
    private static func chmodPath(_ path: String, _ mode: Int) -> Bool {
        // 0o400 minimum so the file is at least readable by us; the archive's
        // own bits carry the executable flag the toolchain needs.
        let value = mode | 0o400
        return (try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: value)], ofItemAtPath: path)) != nil
    }
}
