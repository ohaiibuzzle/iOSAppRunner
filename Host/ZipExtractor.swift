//
//  ZipExtractor.swift
//  iOSAppRunner
//

import Foundation

enum ZipError: LocalizedError {
    case notAZipFile
    case unsupportedCompression(UInt16)
    case corrupt(String)
    case pathEscape(String)
    case decompressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAZipFile: return String(localized: "Not a valid ZIP/IPA archive.")
        case .unsupportedCompression(let m): return String(localized: "Unsupported compression method (\(Int(m))).")
        case .corrupt(let detail): return String(localized: "Corrupt archive: \(detail).")
        case .pathEscape(let name): return String(localized: "Refused to extract entry escaping destination: \(name).")
        case .decompressionFailed(let detail): return String(localized: "Decompression failed: \(detail).")
        }
    }
}

enum ZipExtractor {

    static func extract(zipURL: URL, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let entries = try readCentralDirectory(handle: handle, fileSize: fileSize)

        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let destPath = destination.standardizedFileURL.path
        let destPrefix = destPath.hasSuffix("/") ? destPath : destPath + "/"

        for entry in entries {
            // Normalise the entry name (zip uses forward slashes)
            let cleaned = entry.name.replacingOccurrences(of: "\\", with: "/")
            let outURL = destination.appendingPathComponent(cleaned)
            let outPath = outURL.standardizedFileURL.path

            // Reject path traversal
            guard outPath == destPath || outPath.hasPrefix(destPrefix) else {
                throw ZipError.pathEscape(entry.name)
            }

            if cleaned.hasSuffix("/") {
                try? fm.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }

            try? fm.createDirectory(at: outURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try writeEntry(handle: handle, entry: entry, to: outURL)
        }
    }

    // MARK: - Internal types

    private struct Entry {
        var name: String
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var compressionMethod: UInt16
        var localHeaderOffset: UInt64
        var externalAttributes: UInt32
    }

    // MARK: - Central directory

    /// Central-directory layout decoded from the EOCD / ZIP64 EOCD records.
    private struct CDLayout {
        var offset: UInt64
        var size: UInt64
        var entryCount: UInt64
    }

    private static func readCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> [Entry] {
        let layout = try locateCentralDirectory(handle: handle, fileSize: fileSize)
        try handle.seek(toOffset: layout.offset)
        let cdData = try handle.read(upToCount: Int(layout.size)) ?? Data()
        guard UInt64(cdData.count) == layout.size else {
            throw ZipError.corrupt("Central directory truncated")
        }
        return try parseCentralDirectoryEntries(cdData, count: layout.entryCount)
    }

    /// Scans the trailing region for the End Of Central Directory record and
    /// follows the ZIP64 locator when sentinel values are present.
    private static func locateCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> CDLayout {
        let maxComment: UInt64 = 0xFFFF
        let scanLen = min(maxComment + 22, fileSize)
        let scanStart = fileSize - scanLen
        try handle.seek(toOffset: scanStart)
        let buffer = try handle.read(upToCount: Int(scanLen)) ?? Data()

        guard buffer.count >= 22 else { throw ZipError.notAZipFile }

        let eocdOffset = scanForEOCD(in: buffer)
        guard eocdOffset >= 0 else { throw ZipError.notAZipFile }

        let totalEntries16 = u16(buffer, eocdOffset + 10)
        let cdSize32 = u32(buffer, eocdOffset + 12)
        let cdOffset32 = u32(buffer, eocdOffset + 16)

        var layout = CDLayout(offset: UInt64(cdOffset32),
                              size: UInt64(cdSize32),
                              entryCount: UInt64(totalEntries16))

        // ZIP64 path if any sentinel value is present.
        if totalEntries16 == 0xFFFF || cdSize32 == 0xFFFFFFFF || cdOffset32 == 0xFFFFFFFF {
            layout = try locateZIP64CentralDirectory(handle: handle,
                                                     scanStart: scanStart,
                                                     eocdOffset: UInt64(eocdOffset))
        }
        return layout
    }

    /// Walks backwards looking for the 0x06054b50 EOCD signature.
    private static func scanForEOCD(in buffer: Data) -> Int {
        var i = buffer.count - 22
        while i >= 0 {
            if buffer[i] == 0x50, buffer[i + 1] == 0x4B,
               buffer[i + 2] == 0x05, buffer[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return -1
    }

    /// Reads the ZIP64 locator + ZIP64 EOCD to get the real central-directory
    /// layout (needed for archives with >65535 entries or >4GB payloads).
    private static func locateZIP64CentralDirectory(handle: FileHandle, scanStart: UInt64, eocdOffset: UInt64) throws -> CDLayout {
        let locatorPos = scanStart + eocdOffset - 20
        try handle.seek(toOffset: locatorPos)
        let locator = try handle.read(upToCount: 20) ?? Data()
        guard locator.count == 20,
              locator[0] == 0x50, locator[1] == 0x4B,
              locator[2] == 0x06, locator[3] == 0x07 else {
            throw ZipError.corrupt("ZIP64 locator missing")
        }
        let zip64EOCDOffset = u64(locator, 8)
        try handle.seek(toOffset: zip64EOCDOffset)
        let zip64 = try handle.read(upToCount: 56) ?? Data()
        guard zip64.count >= 56,
              zip64[0] == 0x50, zip64[1] == 0x4B,
              zip64[2] == 0x06, zip64[3] == 0x06 else {
            throw ZipError.corrupt("ZIP64 EOCD missing")
        }
        return CDLayout(offset: u64(zip64, 48), size: u64(zip64, 40), entryCount: u64(zip64, 32))
    }

    private static func parseCentralDirectoryEntries(_ cdData: Data, count: UInt64) throws -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))

        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cdData.count,
                  cdData[p] == 0x50, cdData[p + 1] == 0x4B,
                  cdData[p + 2] == 0x01, cdData[p + 3] == 0x02 else {
                throw ZipError.corrupt("Bad central directory header")
            }

            let (entry, next) = try parseCentralDirectoryEntry(cdData, at: p)
            entries.append(entry)
            p = next
        }
        return entries
    }

    /// Parses one fixed-size central directory record; returns the entry and
    /// the offset of the next record.
    private static func parseCentralDirectoryEntry(_ cdData: Data, at p: Int) throws -> (entry: Entry, next: Int) {
        let method = u16(cdData, p + 10)
        var sizes = EntrySizes(uncompressed: UInt64(u32(cdData, p + 24)),
                               compressed: UInt64(u32(cdData, p + 20)),
                               localHeaderOffset: UInt64(u32(cdData, p + 42)))
        let nameLen = Int(u16(cdData, p + 28))
        let extraLen = Int(u16(cdData, p + 30))
        let commentLen = Int(u16(cdData, p + 32))
        let externalAttr = u32(cdData, p + 38)

        let nameRange = (p + 46)..<(p + 46 + nameLen)
        let nameData = cdData.subdata(in: nameRange)
        let name = String(data: nameData, encoding: .utf8)
            ?? String(data: nameData, encoding: .isoLatin1)
            ?? ""

        // Walk the extra-field block to pull out ZIP64 (id 0x0001) values.
        let extraEnd = parseZIP64ExtraField(cdData, start: p + 46 + nameLen,
                                            end: p + 46 + nameLen + extraLen,
                                            sizes: &sizes)

        let entry = Entry(
            name: name,
            compressedSize: sizes.compressed,
            uncompressedSize: sizes.uncompressed,
            compressionMethod: method,
            localHeaderOffset: sizes.localHeaderOffset,
            externalAttributes: externalAttr
        )
        return (entry, extraEnd + commentLen)
    }

    /// The three values that can be overridden by a ZIP64 extra field.
    private struct EntrySizes {
        var uncompressed: UInt64
        var compressed: UInt64
        var localHeaderOffset: UInt64
    }

    /// Walks the extra-field block at `start..<end`, replacing any 32-bit
    /// sentinel values with their ZIP64 (id 0x0001) 64-bit counterparts.
    /// Returns the end offset of the extra field.
    private static func parseZIP64ExtraField(_ data: Data, start: Int, end: Int,
                                             sizes: inout EntrySizes) -> Int {
        var ep = start
        while ep + 4 <= end {
            let id = u16(data, ep)
            let size = Int(u16(data, ep + 2))
            let payload = ep + 4
            if id == 0x0001 {
                var q = payload
                if sizes.uncompressed == 0xFFFFFFFF, q + 8 <= end {
                    sizes.uncompressed = u64(data, q); q += 8
                }
                if sizes.compressed == 0xFFFFFFFF, q + 8 <= end {
                    sizes.compressed = u64(data, q); q += 8
                }
                if sizes.localHeaderOffset == 0xFFFFFFFF, q + 8 <= end {
                    sizes.localHeaderOffset = u64(data, q); q += 8
                }
            }
            ep = payload + size
        }
        return ep
    }

    // MARK: - Entry extraction

    private static func writeEntry(handle: FileHandle, entry: Entry, to url: URL) throws {
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30,
              header[0] == 0x50, header[1] == 0x4B,
              header[2] == 0x03, header[3] == 0x04 else {
            throw ZipError.corrupt("Bad local file header")
        }
        let nameLen = Int(u16(header, 26))
        let extraLen = Int(u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLen) + UInt64(extraLen)

        try handle.seek(toOffset: dataOffset)
        let raw = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard UInt64(raw.count) == entry.compressedSize else {
            throw ZipError.corrupt("Entry data truncated: \(entry.name)")
        }

        let decoded: Data
        switch entry.compressionMethod {
        case 0:
            decoded = raw
        case 8:
            do {
                decoded = try (raw as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw ZipError.decompressionFailed("\(entry.name): \(error.localizedDescription)")
            }
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }

        let fm = FileManager.default
        let unixMode = UInt16((entry.externalAttributes >> 16) & 0xFFFF)
        let unixType = unixMode & 0xF000

        // Symbolic link: payload is the link target.
        if unixType == 0xA000 {
            let target = String(data: decoded, encoding: .utf8) ?? ""
            try? fm.removeItem(at: url)
            try fm.createSymbolicLink(at: url,
                                      withDestinationURL: URL(fileURLWithPath: target))
            return
        }

        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try decoded.write(to: url, options: .atomic)

        // Preserve POSIX permissions when the archive carries them.
        if unixMode != 0 {
            let perms = NSNumber(value: unixMode & 0x0FFF)
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        }
    }

    // MARK: - Little-endian readers

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << (UInt64(i) * 8)
        }
        return value
    }
}
