//
//  RuntimeLauncher.swift
//  BaseiOSAppHost
//

import AppKit
import Darwin
import Security

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

    // MARK: - Signing expiry

    /// ExpirationDate of a bundle's embedded provisioning profile (7 days on
    /// free Apple IDs); nil when there is none or it can't be decoded. The
    /// profile sits beside the executable (iOS) or one level up (Contents/).
    static func profileExpiry(of bundle: URL) -> Date? {
        guard let execDir = executablePath(of: bundle)?.deletingLastPathComponent() else { return nil }
        let candidates = [execDir, execDir.deletingLastPathComponent()].flatMap { dir in
            ["embedded.mobileprovision", "embedded.provisionprofile"].map { dir.appendingPathComponent($0) }
        }
        guard let data = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
              !data.isEmpty else { return nil }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let updated = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        var content: CFData?
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content,
              let plist = try? PropertyListSerialization.propertyList(from: content as Data, format: nil)
                as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// Earliest profile expiry across the host and both runtimes; they're
    /// built together, so whichever lapses first stops launches.
    static func earliestSigningExpiry() -> Date? {
        let bundles = [Bundle.main.bundleURL, resolveBundle(.catalyst), resolveBundle(.ios)]
        return bundles.compactMap { $0.flatMap(profileExpiry(of:)) }.min()
    }

    /// Replaces LaunchServices' opaque refusal with the actual cause when the
    /// runtime's profile has lapsed.
    private static func explainingExpiry(_ outcome: LaunchOutcome, bundle: URL) -> LaunchOutcome {
        guard !outcome.ok, let expiry = profileExpiry(of: bundle), expiry < Date() else { return outcome }
        let when = expiry.formatted(date: .abbreviated, time: .shortened)
        return LaunchOutcome(ok: false, message: String(localized:
            "The runtime's signing expired on \(when). Rebuild the app with the same Apple ID."))
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
    static func launch(installName: String, guestBundleID: String?, displayName: String) -> LaunchOutcome {
        guard let located = GuestStore.locateInstalledGuest(installName: installName) else {
            return LaunchOutcome(ok: false,
                                 message: String(localized: "\(displayName) is not installed."))
        }
        let mode = GuestStore.runtimeMode(for: located.url)
        let flavor: RuntimeFlavor = mode == .ios ? .ios : .catalyst
        NSLog("[launcher] launch %@ (guest=%@, mode=%@, residence=%@)", installName as NSString,
              (guestBundleID ?? "-") as NSString, mode.rawValue as NSString,
              located.flavor.displayName as NSString)
        guard located.flavor == flavor else {
            return LaunchOutcome(ok: false, message:
                String(localized: """
                    \(displayName) is set to the \(flavor.displayName) runtime, but its data still resides in the \
                    \(located.flavor.displayName) container. Open its Compatibility Settings and close the sheet \
                    to finish the switch.
                    """))
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
                                     message: String(localized: "\(displayName) is already running; quit it first."))
            }
        }

        // The runtime fails closed without a slot, so refuse here with a clear message.
        guard let guestBundleID else {
            return LaunchOutcome(ok: false,
                                 message: String(localized: "\(displayName) has no bundle identifier."))
        }
        guard let slot = KeychainManager.ensureSlot(for: guestBundleID) else {
            return LaunchOutcome(ok: false,
                                 message: String(localized: "Could not assign a keychain slot for \(displayName). Free one by deleting an unused app, then try again."))
        }
        writeDisplayMetrics(flavor)

        switch flavor {
        case .ios:
            guard let bundle = resolveBundle(.ios) else {
                return LaunchOutcome(ok: false,
                                     message: String(localized: "Runtime-iOS.app not found; build and embed the runtime target."))
            }
            return explainingExpiry(launchiOSViaOpen(bundle: ensureWrapped(bundle), installName: installName,
                                                     keychainSlot: slot), bundle: bundle)
        case .catalyst:
            guard let bundle = resolveBundle(.catalyst),
                  let exec = executablePath(of: bundle) else {
                return LaunchOutcome(ok: false,
                                     message: String(localized:
                                         "Runtime bundle not found (Runtime-Catalyst.app); build and embed the runtime targets."))
            }
            return explainingExpiry(launchCatalyst(executable: exec, bundlePath: bundle.path,
                                                   installName: installName, keychainSlot: slot), bundle: bundle)
        }
    }

    private static func keychainSlotArgs(_ slot: Int32) -> [String] {
        ["--keychain-slot", String(slot)]
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
                                       keychainSlot: Int32) -> LaunchOutcome {
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
    private static func launchiOSViaOpen(bundle: URL, installName: String, keychainSlot: Int32) -> LaunchOutcome {
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
        guard let exec = executablePath(of: bundle),
              let pid = pollForRuntimePID(executable: exec, installName: installName, timeout: 8.0) else {
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
            if isStopped(pid) { return true }
            usleep(100 * 1000)
        }
        return false
    }

    // sys/proc.h's SSTOP; the macro isn't visible to Swift.
    private static let sstop: UInt32 = 4

    private static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status == sstop
    }

    // MARK: - Process discovery

    /// proc_pidpath reports the realpath (/private/...), which Foundation's
    /// resolvingSymlinksInPath() strips back to /tmp etc.
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Every pid (except ours) whose executable path is in `executables`.
    private static func pids(running executables: Set<String>) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let listed = proc_listallpids(&pids, Int32(count) * Int32(MemoryLayout<pid_t>.size))
        guard listed > 0 else { return [] }

        // proc_pidpath's buffer size (PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN;
        // the C macro isn't visible to Swift).
        let pathBufferSize = 4 * Int(MAXPATHLEN)
        return pids.prefix(Int(listed)).filter { pid in
            guard pid > 0, pid != getpid() else { return false }
            var buffer = [CChar](repeating: 0, count: pathBufferSize)
            guard proc_pidpath(pid, &buffer, UInt32(pathBufferSize)) > 0 else { return false }
            return executables.contains(String(cString: buffer))
        }
    }

    /// argv of `pid` via KERN_PROCARGS2 (argc, exec path, NUL padding, then argv).
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        let fields = buf[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        // fields[0] is the exec path; argv follows.
        return fields.dropFirst().prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Polls for the stopped runtime process started for exactly this guest:
    /// right executable, `--launch-app <installName>` in argv. A guest can't
    /// run twice (flock), so the match is unique.
    private static func pollForRuntimePID(executable: URL, installName: String, timeout: TimeInterval) -> pid_t? {
        let targets: Set<String> = [realPath(executable)]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for pid in pids(running: targets) where isStopped(pid) {
                guard let argv = arguments(of: pid),
                      let i = argv.firstIndex(of: "--launch-app"),
                      argv.indices.contains(i + 1), argv[i + 1] == installName else { continue }
                return pid
            }
            usleep(100 * 1000)
        }
        return nil
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
        // Reap it when the guest quits, or it lingers as a zombie.
        DispatchQueue.global(qos: .utility).async { _ = waitpid(pid, nil, 0) }
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
                targets.insert(realPath(exec))
            }
        }
        guard !targets.isEmpty else { return 0 }

        let signaled = pids(running: targets)
        for pid in signaled {
            NSLog("[launcher] killing runtime pid %d", pid)
            kill(pid, SIGKILL)
        }
        return signaled.count
    }
}
