//
//  RuntimeLauncher.swift
//  BaseiOSAppHost
//
//  Spawns the minimal runtimes. The host is unsandboxed, so it execs the
//  Catalyst runtime directly with argv — no `pending_launch` claim queue, no
//  LaunchServices dance:
//
//      <runtime exec> --launch-app <installName>
//
//  The iOS runtime ("designed for iPad" build) is a different story:
//  iOS-platform binaries can't be exec'd directly on macOS — the bundle must
//  use the Mac-iOS *wrapped* layout (outer .app containing Wrapper/<inner>.app
//  plus a WrappedBundle symlink; Xcode produces exactly this as the
//  .XCInstall product for Designed-for-iPad builds) and be launched through
//  LaunchServices (`open -n`).
//
//  Furthermore, the runtime's LCDyld library-validation bypass — and guest
//  JIT — only work while the process carries the debugger flag, so the host
//  must attach and detach a debugger around every iOS-runtime launch:
//  the runtime passes --wait-for-host, SIGSTOPs itself at startup, the host
//  finds the pid, does task_for_pid + ptrace(PT_ATTACHEXC) + PT_DETACH
//  (SIGCONT), and the runtime proceeds with AMFI satisfied. No debugger
//  remains attached.
//

import AppKit
import Darwin

// ptrace isn't exported to Swift by the Darwin overlay; bridge it and define
// the request constants ourselves (sys/ptrace.h: PT_DETACH=11, PT_ATTACHEXC=14).
@_silgen_name("ptrace")
private func c_ptrace(_ request: Int32, _ pid: pid_t,
                      _ addr: UnsafeMutableRawPointer?, _ data: Int32) -> Int32

private let PT_DETACH: Int32 = 11
private let PT_ATTACHEXC: Int32 = 14

enum RuntimeFlavor {
    case catalyst
    case ios

    var bundleName: String {
        switch self {
        case .catalyst: return "Runtime-Catalyst.app"
        case .ios: return "Runtime-iOS.app"
        }
    }
}

struct LaunchOutcome {
    let ok: Bool
    let message: String
}

enum RuntimeLauncher {

    // MARK: - Runtime discovery

    /// Locates a runtime app bundle: `BASEIOSAPP_RUNTIME_DIR` override first
    /// (dev builds), then the host bundle's embedded Resources.
    static func resolveBundle(_ flavor: RuntimeFlavor) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["BASEIOSAPP_RUNTIME_DIR"] {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            // Prefer Xcode's pre-wrapped .XCInstall product for the iOS runtime.
            if flavor == .ios {
                let xcinstall = base.appendingPathComponent(".XCInstall")
                    .appendingPathComponent(flavor.bundleName)
                if FileManager.default.fileExists(atPath: xcinstall.path) {
                    return xcinstall
                }
            }
            let candidate = base.appendingPathComponent(flavor.bundleName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent(flavor.bundleName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Locates a runtime's executable across the layouts we support:
    /// Catalyst (Contents/MacOS), Mac-iOS wrapped (Wrapper/<inner>.app), and
    /// flat iOS-built bundles.
    static func executablePath(of bundle: URL) -> URL? {
        let fm = FileManager.default

        // Catalyst / standard macOS layout.
        let macos = bundle.appendingPathComponent("Contents").appendingPathComponent("MacOS")
        if let names = try? fm.contentsOfDirectory(atPath: macos.path),
           let name = names.first(where: { !$0.hasPrefix(".") }) {
            return macos.appendingPathComponent(name)
        }

        // Mac-iOS wrapped layout: Wrapper/<Inner>.app/<exec>.
        let wrapper = bundle.appendingPathComponent("Wrapper")
        if let innerApps = try? fm.contentsOfDirectory(atPath: wrapper.path),
           let inner = innerApps.first(where: { $0.hasSuffix(".app") }) {
            let innerBundle = wrapper.appendingPathComponent(inner)
            if let exec = flatBundleExecutable(in: innerBundle) {
                return exec
            }
        }

        // Flat iOS layout: executable at the bundle root.
        return flatBundleExecutable(in: bundle)
    }

    private static func flatBundleExecutable(in bundle: URL) -> URL? {
        let reserved = ["_CodeSignature", "PkgInfo", "Info.plist", "embedded.mobileprovision"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: bundle.path) else {
            return nil
        }
        let candidates = names.filter { name in
            !name.hasPrefix(".") && name != "entitlements.plist" && !reserved.contains(name)
                && !name.hasSuffix(".plist") && !name.hasSuffix(".app")
        }
        guard let name = candidates.first else { return nil }
        let url = bundle.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// Whether the bundle uses the Mac-iOS wrapped layout.
    static func isWrapped(_ bundle: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Wrapper").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// iOS-platform bundles must be wrapped (Wrapper/<inner>.app + a
    /// WrappedBundle symlink) to be launchable via LaunchServices. Wraps a
    /// flat bundle into a temp directory when needed; wrapped bundles are
    /// returned unchanged.
    static func ensureWrapped(_ bundle: URL) -> URL {
        guard !isWrapped(bundle) else { return bundle }
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("BaseiOSApp-runtime-\(UUID().uuidString)", isDirectory: true)
        let outer = tmpRoot.appendingPathComponent(bundle.lastPathComponent)
        let wrapperDir = outer.appendingPathComponent("Wrapper", isDirectory: true)
        do {
            try fm.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
            try fm.copyItem(at: bundle, to: wrapperDir.appendingPathComponent(bundle.lastPathComponent))
            try fm.createSymbolicLink(
                at: outer.appendingPathComponent("WrappedBundle"),
                withDestinationURL: URL(string: "Wrapper/\(bundle.lastPathComponent)")!)
        } catch {
            NSLog("[launcher] failed to wrap %@: %@", bundle.path as NSString, error.localizedDescription)
            return bundle
        }
        return outer
    }

    // MARK: - Host display metrics hand-off

    /// Written right before spawning a guest; `Resolution.m` reads it back to
    /// size the guest's fake `UIScreen` to the Mac's real display. The old
    /// launcher measured from its own Catalyst window; the native host just
    /// reads AppKit directly.
    static func writeDisplayMetrics() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame   // excludes menu bar + Dock
        let metrics: [String: Any] = [
            "width": Double(visibleFrame.width),
            "height": Double(visibleFrame.height),
            "scale": Double(screen.backingScaleFactor),
            "frameX": Double(visibleFrame.origin.x),
            "frameY": Double(visibleFrame.origin.y),
            "frameWidth": Double(visibleFrame.width),
            "frameHeight": Double(visibleFrame.height),
        ]
        (metrics as NSDictionary).write(to: GuestPaths.displayResolutionFile, atomically: true)
    }

    // MARK: - Launch

    /// Launches a guest under the runtime selected by its `runtime` mode.
    /// `auto` prefers Catalyst and falls back to iOS.
    static func launch(installName: String, mode: RuntimeMode) -> LaunchOutcome {
        writeDisplayMetrics()

        switch mode {
        case .ios:
            return launchiOS(installName: installName, attachDebugger: true)
        case .catalyst, .auto:
            guard let bundle = resolveBundle(.catalyst),
                  let exec = executablePath(of: bundle) else {
                if mode == .auto {
                    return launchiOS(installName: installName, attachDebugger: true)
                }
                return LaunchOutcome(ok: false,
                                     message: "Runtime bundle not found (Runtime-Catalyst.app); build and embed the runtime targets.")
            }
            return launchCatalyst(executable: exec, bundlePath: bundle.path, installName: installName)
        }
    }

    /// Launches a guest under the iOS runtime. The debugger attach is not
    /// optional for correctness — the runtime's library-validation bypass
    /// (and guest JIT) require it — but it can be skipped deliberately to
    /// debug the runtime itself (the guest will then fail to load).
    static func launchiOS(installName: String, attachDebugger: Bool) -> LaunchOutcome {
        guard let bundle = resolveBundle(.ios) else {
            return LaunchOutcome(ok: false,
                                 message: "Runtime-iOS.app not found; build and embed the runtime target.")
        }
        writeDisplayMetrics()
        return launchiOSViaOpen(bundle: ensureWrapped(bundle),
                                installName: installName,
                                attachDebugger: attachDebugger)
    }

    // MARK: - Catalyst spawning (direct exec)

    private static func launchCatalyst(executable: URL, bundlePath: String, installName: String) -> LaunchOutcome {
        let rc = spawn(executable: executable.path, args: ["--launch-app", installName])
        if rc == 0 {
            return LaunchOutcome(ok: true, message: "Launched via Catalyst runtime")
        }

        NSLog("[launcher] direct Catalyst spawn failed (rc=%d); falling back to open -n --args", rc)
        return openFallback(bundlePath: bundlePath, installName: installName,
                            successMessage: "Launched via Catalyst runtime (open)",
                            failurePrefix: "Failed to launch Catalyst runtime")
    }

    /// Launches a runtime bundle via `open -n --args`, capturing stderr so
    /// the caller sees LaunchServices' actual complaint.
    private static func openFallback(bundlePath: String, installName: String,
                                     successMessage: String, failurePrefix: String) -> LaunchOutcome {
        let (status, stderrText) = runOpen(bundlePath: bundlePath, arguments: ["--launch-app", installName])
        if status == 0 {
            return LaunchOutcome(ok: true, message: successMessage)
        }
        let detail = stderrText.isEmpty ? "open exited with \(status)" : stderrText
        return LaunchOutcome(ok: false, message: "\(failurePrefix): \(detail)")
    }

    // MARK: - iOS runtime (LaunchServices + debugger attach)

    /// Launches the wrapped iOS runtime through LaunchServices. When
    /// `attachDebugger` is set, the runtime is launched with --wait-for-host
    /// (it SIGSTOPs itself at startup) and the host finds the spawned pid and
    /// attaches/detaches so AMFI's library-validation checks (and guest JIT)
    /// are satisfied before any guest dylib is loaded.
    private static func launchiOSViaOpen(bundle: URL, installName: String, attachDebugger: Bool) -> LaunchOutcome {
        // Strip quarantine/xattrs so Gatekeeper doesn't flag the dev-signed
        // (unnotarized) bundle as damaged.
        c_stripXattrsRecursive(bundle.path)

        var openArgs = ["--launch-app", installName]
        if attachDebugger {
            openArgs.append("--wait-for-host")
        }
        let (status, stderrText) = runOpen(bundlePath: bundle.path, arguments: openArgs)
        guard status == 0 else {
            let detail = stderrText.isEmpty ? "open exited with \(status)" : stderrText
            return LaunchOutcome(ok: false, message: "Failed to launch iOS runtime: \(detail)")
        }

        guard attachDebugger else {
            return LaunchOutcome(ok: true,
                                 message: "Launched via iOS runtime (debugger attach disabled; guests will fail to load)")
        }

        // The runtime SIGSTOPs itself right after spawn; find it and attach.
        guard let pid = pollForRuntimePID(timeout: 8.0) else {
            return LaunchOutcome(ok: false,
                                 message: "iOS runtime launched but the host could not find its process to attach the debugger (guests will fail to load). Try again.")
        }
        attachHostDebugger(pid: pid)
        return LaunchOutcome(ok: true,
                             message: "Launched via iOS runtime (debugger attached for library-validation bypass/JIT)")
    }

    /// task_for_pid + ptrace(PT_ATTACHEXC)/PT_DETACH. Both binaries are
    /// dev-signed by the same team and the runtime keeps get-task-allow, so
    /// task_for_pid is permitted. The attach sets the CS_DEBUGGED flag AMFI
    /// consults for dynamic code / library validation; the detach leaves the
    /// flag set, so no debugger remains attached afterwards.
    @discardableResult
    private static func attachHostDebugger(pid: pid_t) -> Bool {
        var task: mach_port_t = 0
        let kr = task_for_pid(mach_task_self_, pid, &task)
        guard kr == KERN_SUCCESS else {
            NSLog("[launcher] task_for_pid(%d) failed: %d (guests will not load; JIT disabled)", pid, kr)
            return false
        }
        guard c_ptrace(PT_ATTACHEXC, pid, nil, 0) != -1 else {
            NSLog("[launcher] ptrace(PT_ATTACHEXC) failed: errno %d", errno)
            return false
        }
        if c_ptrace(PT_DETACH, pid, nil, SIGCONT) == -1 {
            NSLog("[launcher] ptrace(PT_DETACH) failed: errno %d", errno)
            return false
        }
        // PT_DETACH's signal alone doesn't clear a job-control (SIGSTOP) stop;
        // resume the process explicitly.
        kill(pid, SIGCONT)
        NSLog("[launcher] debugger attached+detached for runtime pid %d", pid)
        return true
    }

    // MARK: - Process discovery

    private static var knownRuntimePIDs = Set<pid_t>()
    private static let pidLock = NSLock()

    /// Polls for LaunchServices-staged iOS runtime processes (their staged
    /// executable path always contains Wrapper/Runtime-iOS.app). Returns the
    /// first pid not seen before.
    private static func pollForRuntimePID(timeout: TimeInterval) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for pid in findRuntimePIDs() {
                var isNew = false
                pidLock.lock()
                if !knownRuntimePIDs.contains(pid) {
                    knownRuntimePIDs.insert(pid)
                    isNew = true
                }
                pidLock.unlock()
                if isNew {
                    return pid
                }
            }
            usleep(100 * 1000)
        }
        return nil
    }

    private static func findRuntimePIDs() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "Wrapper/Runtime-iOS.app/Runtime-iOS"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? stdout.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { pid_t(Int($0.trimmingCharacters(in: .whitespaces)) ?? 0) }.filter { $0 != 0 }
    }

    // MARK: - Low-level helpers

    @discardableResult
    private static func runOpen(bundlePath: String, arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath, "--args"] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        process.waitUntilExit()
        let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    /// Direct exec of the Catalyst runtime. On failure (WindowServer/TCC
    /// quirks), fall back to `open -n --args`, which is still argv-capable.
    private static func spawn(executable: String, args: [String]) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] =
            [strdup(executable)] + args.map { strdup($0) } + [nil]
        var envp = currentEnvp()
        defer {
            for case let p? in argv { free(p) }
            for case let p? in envp { free(p) }
        }

        var pid: pid_t = 0
        let rc = executable.withCString { execC in
            argv.withUnsafeMutableBufferPointer { argvBuf in
                envp.withUnsafeMutableBufferPointer { envBuf in
                    posix_spawn(&pid, execC, nil, nil, argvBuf.baseAddress!, envBuf.baseAddress!)
                }
            }
        }
        guard rc == 0 else {
            NSLog("[launcher] posix_spawn(%@) failed: rc=%d errno=%d", executable as NSString, rc, errno)
            return rc
        }

        // A spawned runtime that dies immediately (AMFI/sandbox refusal)
        // shouldn't count as a successful launch.
        usleep(300 * 1000)
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            NSLog("[launcher] spawned runtime pid %d died immediately (status=0x%x)", pid, status)
            return -1
        }
        return 0
    }

    private static func currentEnvp() -> [UnsafeMutablePointer<CChar>?] {
        ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    }
}
