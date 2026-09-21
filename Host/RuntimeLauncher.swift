//
//  RuntimeLauncher.swift
//  BaseiOSAppHost
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

    /// Host Info.plist key carrying this flavor's bundle ID. The two flavors
    /// have separate IDs so LaunchServices treats them as distinct apps and
    /// both can run at the same time (a shared ID made `open` on the second
    /// flavor just activate the already-running instance).
    var infoPlistBundleIDKey: String {
        switch self {
        case .catalyst: return "RuntimeCatalystBundleIdentifier"
        case .ios: return "RuntimeiOSBundleIdentifier"
        }
    }

    var displayName: String {
        self == .catalyst ? "Catalyst" : "iOS"
    }

    /// This flavor's bundle ID from the host's Info.plist (nil when the key
    /// is missing or still carries an unexpanded build setting).
    var bundleIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistBundleIDKey) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
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

    /// Written right before spawning a guest; `Resolution.m` reads it back to
    /// size the guest's fake `UIScreen` to the Mac's real display. The old
    /// launcher measured from its own Catalyst window; the native host just
    /// reads AppKit directly. Each runtime flavor reads it from its own
    /// container, so it lands in the flavor that's actually being launched.
    static func writeDisplayMetrics(_ flavor: RuntimeFlavor) {
        // NSScreen is read on the main thread; the launcher itself runs on a
        // background queue.
        let metrics: [String: Any]? = {
            let read = {
                guard let screen = NSScreen.main else { return nil as [String: Any]? }
                let visibleFrame = screen.visibleFrame   // excludes menu bar + Dock
                return ["width": Double(visibleFrame.width),
                        "height": Double(visibleFrame.height),
                        "scale": Double(screen.backingScaleFactor),
                        "frameX": Double(visibleFrame.origin.x),
                        "frameY": Double(visibleFrame.origin.y),
                        "frameWidth": Double(visibleFrame.width),
                        "frameHeight": Double(visibleFrame.height)] as [String: Any]
            }
            return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
        }()
        guard let metrics else { return }
        (metrics as NSDictionary).write(to: GuestPaths.displayResolutionFile(for: flavor), atomically: true)
    }

    // MARK: - Launch

    /// Launches a guest under the runtime selected by its `runtime` mode.
    /// `auto` prefers Catalyst and falls back to iOS.
    ///
    /// Guests live in exactly one runtime container; before spawning, the
    /// guest is migrated into the effective flavor's container
    /// (ensureGuestResides) so flavor switches — including the silent `auto`
    /// fallback — carry the guest's data along. The guest's keychain slot is
    /// claimed here too and passed to the runtime: the flavors live in
    /// separate sandbox containers, so the runtime never negotiates slots
    /// itself anymore.
    static func launch(installName: String, guestBundleID: String?, mode: RuntimeMode) -> LaunchOutcome {
        NSLog("[launcher] launch %@ (guest=%@, mode=%@)", installName as NSString,
              (guestBundleID ?? "-") as NSString, mode.rawValue as NSString)
        let flavor = effectiveFlavor(for: mode)
        NSLog("[launcher] effectiveFlavor=%@ container=%@",
              flavor.displayName as NSString,
              GuestPaths.containerDirectory(for: flavor).path as NSString)

        // Mac-iOS wrapped runtimes get their sandbox container from
        // containermanagerd at first LaunchServices registration — a
        // UUID-named directory the runtime spills via its container marker
        // (see GuestPaths.runtimeMarkerFileName). On a fresh install that
        // container doesn't exist yet, so register the runtime once (the
        // headless runtime exits immediately with no --launch-app) and wait
        // for the assignment before placing the guest anywhere.
        if flavor == .ios {
            guard resolveBundle(.ios) != nil else {
                return LaunchOutcome(ok: false,
                                     message: String(localized: "Runtime-iOS.app not found; build and embed the runtime target."))
            }
            let iosBundleID = RuntimeFlavor.ios.bundleIdentifier
                ?? Bundle.main.bundleIdentifier ?? ""
            // The iOS runtime spills its UUID-named container assignment via
            // a marker file (see GuestPaths.runtimeMarkerFileName). Cache is
            // validated per launch; on a cold cache, try the cheap scan,
            // then priming (register the runtime once so containermanagerd
            // assigns a container) before placing any guest.
            if GuestPaths.knownMacIOSContainerName(for: iosBundleID) == nil {
                if GuestPaths.discoverMacIOSContainerName(for: iosBundleID) == nil,
                   !primeIOSRuntimeContainer(bundleID: iosBundleID) {
                    return LaunchOutcome(ok: false,
                                         message: String(localized: "Could not set up the iOS runtime container; try again."))
                }
            }
        }

        do {
            try GuestStore.ensureGuestResides(installName: installName,
                                              guestBundleID: guestBundleID,
                                              target: flavor)
        } catch {
            return LaunchOutcome(ok: false, message: error.localizedDescription)
        }

        // Refuse to double-launch: the runtime holds the guest's flock while
        // it runs, so a failed probe means an instance is live. (A guest
        // running in the *other* container is caught earlier — the migration
        // above refuses to move it.)
        if let guestBundleID {
            let targetHome = GuestPaths.guestHome(guestBundleID, in: flavor)
            if FileManager.default.fileExists(atPath: targetHome.path),
               GuestPaths.guestIsRunning(guestHome: targetHome) {
                return LaunchOutcome(ok: false,
                                     message: String(localized: "\(installName) is already running; quit it first."))
            }
        }

        let slot = guestBundleID.flatMap { KeychainManager.ensureSlot(for: $0) }
        writeDisplayMetrics(flavor)

        switch flavor {
        case .ios:
            guard let bundle = resolveBundle(.ios) else {
                return LaunchOutcome(ok: false,
                                     message: String(localized: "Runtime-iOS.app not found; build and embed the runtime target."))
            }
            return launchiOSViaOpen(bundle: ensureWrapped(bundle), installName: installName,
                                    keychainSlot: slot)
        case .catalyst:
            guard let bundle = resolveBundle(.catalyst),
                  let exec = executablePath(of: bundle) else {
                return LaunchOutcome(ok: false,
                                     message: String(localized:
                                         "Runtime bundle not found (Runtime-Catalyst.app); build and embed the runtime targets."))
            }
            return launchCatalyst(executable: exec, bundlePath: bundle.path,
                                  installName: installName, keychainSlot: slot)
        }
    }

    /// The runtime a launch will actually use: explicit `ios` always wins;
    /// `catalyst`/`auto` prefer Catalyst and fall back to iOS when the
    /// Catalyst runtime bundle is unavailable.
    static func effectiveFlavor(for mode: RuntimeMode) -> RuntimeFlavor {
        guard mode != .ios else { return .ios }
        if let bundle = resolveBundle(.catalyst), executablePath(of: bundle) != nil {
            return .catalyst
        }
        return .ios
    }

    /// --keychain-slot arguments for a pre-claimed slot; empty when the slot
    /// couldn't be claimed (the runtime then falls back to its legacy
    /// self-claim path).
    private static func keychainSlotArgs(_ slot: Int32?) -> [String] {
        guard let slot, slot > 0 else { return [] }
        return ["--keychain-slot", String(slot)]
    }

    /// Registers the iOS runtime with LaunchServices so containermanagerd
    /// assigns its UUID-named sandbox container. The headless runtime exits
    /// immediately when launched without --launch-app, but not before it
    /// writes its container marker (see main.m / GuestPaths), so the host
    /// just polls the cheap marker scan.
    private static func primeIOSRuntimeContainer(bundleID: String) -> Bool {
        guard let bundle = resolveBundle(.ios) else { return false }
        let wrapped = ensureWrapped(bundle)
        // Strip quarantine/xattrs so Gatekeeper doesn't flag the dev-signed
        // (unnotarized) bundle as damaged.
        _ = c_stripXattrsRecursive(wrapped.path)
        let (status, stderrText) = runOpen(bundlePath: wrapped.path, arguments: [])
        guard status == 0 else {
            NSLog("[launcher] priming open failed: %@", stderrText as NSString)
            return false
        }

        NSLog("[launcher] priming iOS runtime container registration…")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if GuestPaths.discoverMacIOSContainerName(for: bundleID) != nil {
                NSLog("[launcher] iOS runtime container discovered")
                return true
            }
            usleep(200 * 1000)
        }
        NSLog("[launcher] iOS runtime container was not discovered within 15s")
        return false
    }

    // MARK: - Catalyst spawning (direct exec)

    private static func launchCatalyst(executable: URL, bundlePath: String, installName: String,
                                       keychainSlot: Int32? = nil) -> LaunchOutcome {
        let args = ["--launch-app", installName] + keychainSlotArgs(keychainSlot)
        let rc = spawn(executable: executable.path, args: args)
        if rc == 0 {
            return LaunchOutcome(ok: true, message: String(localized: "Launched via Catalyst runtime"))
        }

        NSLog("[launcher] direct Catalyst spawn failed (rc=%d); falling back to open -n --args", rc)
        return openFallback(bundlePath: bundlePath, arguments: args,
                            successMessage: String(localized: "Launched via Catalyst runtime (open)"),
                            failurePrefix: String(localized: "Failed to launch Catalyst runtime"))
    }

    /// Launches a runtime bundle via `open -n --args`, capturing stderr so
    /// the caller sees LaunchServices' actual complaint.
    private static func openFallback(bundlePath: String, arguments: [String],
                                     successMessage: String, failurePrefix: String) -> LaunchOutcome {
        let (status, stderrText) = runOpen(bundlePath: bundlePath, arguments: arguments)
        if status == 0 {
            return LaunchOutcome(ok: true, message: successMessage)
        }
        let detail = stderrText.isEmpty ? String(localized: "open exited with \(status)") : stderrText
        return LaunchOutcome(ok: false, message: String(localized: "\(failurePrefix): \(detail)"))
    }

    // MARK: - iOS runtime (LaunchServices + debugger attach)

    /// Launches the wrapped iOS runtime through LaunchServices. The runtime
    /// is launched with --wait-for-host (it SIGSTOPs itself at startup) and
    /// the host finds the spawned pid and attaches/detaches so AMFI's
    /// library-validation checks (and guest JIT) are satisfied before any
    /// guest dylib is loaded.
    private static func launchiOSViaOpen(bundle: URL, installName: String, keychainSlot: Int32? = nil) -> LaunchOutcome {
        // Strip quarantine/xattrs so Gatekeeper doesn't flag the dev-signed
        // (unnotarized) bundle as damaged.
        _ = c_stripXattrsRecursive(bundle.path)

        let arguments = ["--launch-app", installName, "--wait-for-host"] + keychainSlotArgs(keychainSlot)
        let (status, stderrText) = runOpen(bundlePath: bundle.path,
                                           arguments: arguments)
        guard status == 0 else {
            let detail = stderrText.isEmpty ? String(localized: "open exited with \(status)") : stderrText
            return LaunchOutcome(ok: false, message: String(localized: "Failed to launch iOS runtime: \(detail)"))
        }

        // The runtime SIGSTOPs itself right after spawn; find it and attach.
        guard let pid = pollForRuntimePID(timeout: 8.0) else {
            return LaunchOutcome(ok: false,
                                 message: String(localized: "iOS runtime launched, but its process can't be found. Try again."))
        }
        attachHostDebugger(pid: pid)
        return LaunchOutcome(ok: true,
                             message: String(localized: "Launched via iOS runtime"))
    }

    /// task_for_pid + ptrace(PT_ATTACHEXC)/PT_DETACH. Both binaries are
    /// dev-signed by the same team and the runtime keeps get-task-allow, so
    /// task_for_pid is permitted. The attach sets the CS_DEBUGGED flag AMFI
    /// consults for dynamic code / library validation; the detach leaves the
    /// flag set, so no debugger remains attached afterwards.
    @discardableResult
    private static func attachHostDebugger(pid: pid_t) -> Bool {
        // The runtime SIGSTOPs itself at startup; attaching before that stop
        // has landed catches the process running, and PT_ATTACHEXC then
        // leaves it in an exception suspension PT_DETACH cannot clear
        // (errno 16 / EBUSY) — the process never recovers. Wait for the
        // kernel-visible stopped state first.
        if !waitForStoppedState(pid: pid, timeout: 10) {
            NSLog("[launcher] runtime pid %d never reached its debugger stop; attaching anyway", pid)
        }
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

    /// Waits until the process shows the kernel 'T' (stopped) state. The
    /// runtime's waitForDebugger SIGSTOP is what produces it.
    private static func waitForStoppedState(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = processState(pid: pid), state.hasPrefix("T") {
                return true
            }
            usleep(100 * 1000)
        }
        return false
    }

    private static func processState(pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", String(pid)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard let data = try? stdout.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
