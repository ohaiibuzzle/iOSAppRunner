//
//  ZipExtractor.swift
//  iOSAppRunner
//

import Foundation

enum ZipError: LocalizedError {
    case notAZipFile
    case pathEscape(String)
    case decompressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAZipFile: return String(localized: "Not a valid ZIP/IPA archive.")
        case .pathEscape(let name): return String(localized: "Refused to extract entry escaping destination: \(name).")
        case .decompressionFailed(let detail): return String(localized: "Decompression failed: \(detail).")
        }
    }
}

enum ZipExtractor {

    /// Streams the archive to disk with ditto (no whole-entry buffering), then
    /// rejects anything that points outside `destination`.
    static func extract(zipURL: URL, to destination: URL) throws {
        // ditto silently re-roots "../" entries; refuse them instead.
        let (names, _, listOK) = try run("/usr/bin/zipinfo", ["-1", zipURL.path])
        guard listOK else { throw ZipError.notAZipFile }
        for name in names.split(separator: "\n") {
            let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
            if name.hasPrefix("/") || parts.contains("..") { throw ZipError.pathEscape(String(name)) }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let (_, err, ok) = try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, destination.path])
        guard ok else { throw ZipError.decompressionFailed(err.trimmingCharacters(in: .whitespacesAndNewlines)) }

        // Symlinks must resolve inside the destination (enumerator doesn't follow them).
        let root = destination.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let items = fm.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = items?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  let raw = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let target = URL(fileURLWithPath: raw, relativeTo: url.deletingLastPathComponent())
                .standardizedFileURL.resolvingSymlinksInPath().path
            guard target == root || target.hasPrefix(prefix) else {
                throw ZipError.pathEscape(url.path.replacingOccurrences(of: prefix, with: ""))
            }
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws -> (out: String, err: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Drain stderr on a side queue so a chatty tool can't fill the pipe and stall.
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self),
                p.terminationStatus == 0)
    }
}
