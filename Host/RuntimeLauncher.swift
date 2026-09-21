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

    /// Written before spawning a guest; Resolution.m reads it to size the
    /// guest's fake UIScreen. Each flavor reads it from its own container.
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

    /// Launches a guest under its configured runtime. The mode is read from
    /// the bundle's actual residence (never a UI-cached URL); migration is
    /// the Compat sheet's job, so a residence/mode mismatch is an interrupted
    /// switch and is refused (fail closed). The keychain slot is claimed here
    /// and passed to the runtime — the runtime never negotiates slots itself.
    static func launch(installName: String, guestBundleID: String?) -> LaunchOutcome {
        guard let located = GuestStore.locateInstalledGuest(installName: installName) else {
            return LaunchOutcome(ok: false,
                                 message: String(localized: "\(installName) is not installed."))
        }
        let mode = GuestStore.runtimeMode(for: located.url)
        let flavor: RuntimeFlavor = mode == .ios ? .ios : .catalyst
        NSLog("[launcher] launch %@ (guest=%@, mode=%@, residence=%@)", installName as NSString,
              (guestBundleID ?? "-") as NSString, mode.rawValue as NSString,
              located.flavor.displayName as NSString)
        guard located.flavor == flavor else {
            return LaunchOutcome(ok: false, message:
                String(localized:
                    "\(installName) is set to the \(flavor.displayName) runtime, but its data still resides in the \(located.flavor.displayName) container.")
                + String(localized:
                    " Open its Compatibility Settings and close the sheet to finish the switch."))
        }

        // The iOS runtime's UUID-named container may not exist yet on a fresh
        // install; prime (register once) before touching any guest.
        if flavor == .ios {
            guard resolveBundle(.ios) != nil else {
                return LaunchOutcome(ok: false,
                                     message: String(localized: "Runtime-iOS.app not found; build and embed the runtime target."))
            }
            // Cache is validated per launch; on a cold cache, scan, then prime.
            guard ensureIOSRuntimeContainer() else {
                return LaunchOutcome(ok: false,
                                     message: String(localized: "Could not set up the iOS runtime container; try again."))
            }
        }

        do {
            // Migration happens at Compat-sheet close; this only catches a
            // guest stranded outside both flavor containers.
            try GuestStore.ensureGuestResides(installName: installName,
                                              guestBundleID: guestBundleID,
                                              target: flavor)
        } catch {
            return LaunchOutcome(ok: false, message: error.localizedDescription)
        }

        // Refuse double-launch: a failed flock probe means an instance is live.
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

    /// --keychain-slot args for a pre-claimed slot; empty on claim failure
    /// (the runtime falls back to its legacy self-claim path).
    private static func keychainSlotArgs(_ slot: Int32?) -> [String] {
        guard let slot, slot > 0 else { return [] }
        return ["--keychain-slot", String(slot)]
    }

    /// Ensures the iOS runtime's UUID-named container is known: warm-cache
    /// no-op, else scan, else register the headless runtime with
    /// LaunchServices and wait for containermanagerd's assignment.
    /// Lock-serialized so concurrent callers can't double-register.
    static func ensureIOSRuntimeContainer() -> Bool {
        let bundleID = RuntimeFlavor.ios.bundleIdentifier
            ?? Bundle.main.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else { return false }
        containerPrimeLock.lock()
        defer { containerPrimeLock.unlock() }
        if GuestPaths.knownMacIOSContainerName(for: bundleID) != nil { return true }
        if GuestPaths.discoverMacIOSContainerName(for: bundleID) != nil { return true }
        NSLog("[launcher] iOS runtime container unknown; priming…")
        return primeIOSRuntimeContainer(bundleID: bundleID)
    }

    private static let containerPrimeLock = NSLock()

    /// Registers the headless runtime with LaunchServices; it spills its
    /// container marker on the way out, and the host polls for it.
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

    /// Launches the wrapped iOS runtime via LaunchServices. The runtime
    /// SIGSTOPs itself (--wait-for-host) and the host attaches/detaches a
    /// debugger so AMFI library validation and guest JIT are satisfied.
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

    /// task_for_pid + ptrace attach/detach. The attach sets the CS_DEBUGGED
    /// flag AMFI consults for dynamic code / library validation; it stays set
    /// after the detach.
    @discardableResult
    private static func attachHostDebugger(pid: pid_t) -> Bool {
        // Attaching before the SIGSTOP lands can leave PT_ATTACHEXC in an
        // exception suspension PT_DETACH cannot clear (EBUSY); wait for the
        // kernel 'T' state first.
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
        // PT_DETACH's signal doesn't clear a SIGSTOP stop; resume explicitly.
        kill(pid, SIGCONT)
        NSLog("[launcher] debugger attached+detached for runtime pid %d", pid)
        return true
    }

    /// Waits for the kernel 'T' (stopped) state produced by the runtime's SIGSTOP.
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

    /// Polls for iOS runtime processes (staged paths always contain
    /// Wrapper/Runtime-iOS.app); returns the first pid not seen before.
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

    /// Direct exec of the Catalyst runtime, with argv; on failure falls back
    /// to `open -n --args` (WindowServer/TCC quirks).
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

        // A runtime that dies immediately (AMFI/sandbox refusal) doesn't
        // count as a successful launch.
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

    // MARK: - Killing runtimes

    /// Terminates every running runtime process (both flavors). Each guest
    /// runs inside its runtime process, so this also stops the guests and
    /// releases their `.guest.lock` flocks. Returns the number of processes
    /// signaled.
    static func killAllRuntimes() -> Int {
        var targets = Set<String>()
        for flavor in [RuntimeFlavor.catalyst, RuntimeFlavor.ios] {
            if let bundle = resolveBundle(flavor), let exec = executablePath(of: bundle) {
                targets.insert(exec.standardizedFileURL.path)
            }
        }
        guard !targets.isEmpty else { return 0 }

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let listed = proc_listallpids(&pids, Int32(count) * Int32(MemoryLayout<pid_t>.size))
        guard listed > 0 else { return 0 }

        var signaled: [pid_t] = []
        // proc_pidpath's buffer size (PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN;
        // the C macro isn't visible to Swift).
        let pathBufferSize = 4 * Int(MAXPATHLEN)
        for pid in pids.prefix(Int(listed)) where pid > 0 && pid != getpid() {
            var buffer = [CChar](repeating: 0, count: pathBufferSize)
            guard proc_pidpath(pid, &buffer, UInt32(pathBufferSize)) > 0 else { continue }
            guard targets.contains(String(cString: buffer)) else { continue }
            NSLog("[launcher] killing runtime pid %d", pid)
            kill(pid, SIGTERM)
            signaled.append(pid)
        }
        let total = signaled.count

        // Escalate to SIGKILL for anything that ignores SIGTERM.
        let deadline = Date().addingTimeInterval(2)
        while !signaled.isEmpty && Date() < deadline {
            signaled = signaled.filter { kill($0, 0) == 0 && errno != ESRCH }
            if !signaled.isEmpty { usleep(100 * 1000) }
        }
        for pid in signaled {
            NSLog("[launcher] runtime pid %d ignored SIGTERM; sending SIGKILL", pid)
            kill(pid, SIGKILL)
        }
        return total
    }
}
