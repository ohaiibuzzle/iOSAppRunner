// Self-check for ZipExtractor; run via Tests/run-zip-tests.sh.
import Foundation

@main
struct ZipExtractorTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("zip-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let outside = tmp.appendingPathComponent("outside")   // symlink target, outside every destination
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)

        // Normal file extracts.
        let ok = try makeZip(tmp, "ok", """
            z.writestr("Payload/A.app/hello.txt", "hi")
            """)
        let okDest = tmp.appendingPathComponent("ok-dest")
        try ZipExtractor.extract(zipURL: ok, to: okDest)
        let got = try String(contentsOf: okDest.appendingPathComponent("Payload/A.app/hello.txt"), encoding: .utf8)
        precondition(got == "hi", "normal entry not extracted")

        // ../ entry is rejected and nothing lands next to the destination.
        let dots = try makeZip(tmp, "dots", #"z.writestr("../escaped.txt", "x")"#)
        let dotsDest = tmp.appendingPathComponent("dots/dest")
        try expectEscape(dots, dotsDest, "../ entry")
        precondition(!fm.fileExists(atPath: tmp.appendingPathComponent("dots/escaped.txt").path), "../ entry written")

        // Symlink -> outside, then a file under it: rejected, nothing written outside.
        let sym = try makeZip(tmp, "sym", """
            i = zipfile.ZipInfo("Payload/A.app/x"); i.create_system = 3
            i.external_attr = 0o120755 << 16
            z.writestr(i, "\(outside.path)")
            z.writestr("Payload/A.app/x/evil.plist", "pwn")
            """)
        try expectEscape(sym, tmp.appendingPathComponent("sym-dest"), "symlink trick", anyError: true)
        let leaked = try fm.contentsOfDirectory(atPath: outside.path)
        precondition(leaked.isEmpty, "wrote through symlink")

        // A bare escaping symlink is caught by the post-extract walk.
        let bare = try makeZip(tmp, "bare", """
            i = zipfile.ZipInfo("Payload/A.app/x"); i.create_system = 3
            i.external_attr = 0o120755 << 16
            z.writestr(i, "\(outside.path)")
            """)
        try expectEscape(bare, tmp.appendingPathComponent("bare-dest"), "bare symlink")

        print("zip_extractor_tests: all passed")
    }

    static func expectEscape(_ zip: URL, _ dest: URL, _ what: String, anyError: Bool = false) throws {
        do {
            try ZipExtractor.extract(zipURL: zip, to: dest)
        } catch ZipError.pathEscape { return }
        catch where anyError { return }  // ditto itself may refuse to write under the extracted symlink
        catch { preconditionFailure("\(what): wrong error \(error)") }
        preconditionFailure("\(what) was not rejected")
    }

    /// Builds <dir>/<name>.zip by running `body` (Python, with `z` a ZipFile and `zipfile` imported).
    static func makeZip(_ dir: URL, _ name: String, _ body: String) throws -> URL {
        let out = dir.appendingPathComponent("\(name).zip")
        let script = "import zipfile,sys\nwith zipfile.ZipFile(sys.argv[1], 'w') as z:\n"
            + body.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", script, out.path]
        try p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "python failed building \(name)")
        return out
    }
}
