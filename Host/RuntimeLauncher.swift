//
//  RuntimeLauncher.swift
//  BaseiOSAppHost
//

import AppKit
import Darwin
import Security

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
        if let refusal = preflightRefusal(installName: installName, guestBundleID: guestBundleID,
                                          displayName: displayName, flavor: flavor) {
            return refusal
        }

        // The runtime fails closed without a slot, so refuse here with a clear message.
        guard let guestBundleID else {
            return LaunchOutcome(ok: false,
                                 message: String(localized: "\(displayName) has no bundle identifier."))
        }
        guard let slot = KeychainManager.ensureSlot(for: guestBundleID) else {
            // swiftlint:disable:next line_length
            return LaunchOutcome(ok: false, message: String(localized: "Could not assign a keychain slot for \(displayName). Free one by deleting an unused app, then try again."))
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

    /// Container priming, residence repair and the double-launch probe;
    /// nil when the guest may launch.
    private static func preflightRefusal(installName: String, guestBundleID: String?,
                                         displayName: String, flavor: RuntimeFlavor) -> LaunchOutcome? {
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
        return nil
    }

    static func keychainSlotArgs(_ slot: Int32) -> [String] {
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
}
