//
//  LauncherApp.swift
//  iOSAppRunner
//
//  SwiftUI launcher used when no app has been selected.
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin

// MARK: - Bridge to the on-device install/conversion pipeline.
//
// Functions are exposed as plain C symbols from Dylibifier.m and
// MachOPatcher.m, so we can reach them directly via @_silgen_name
// without a bridging header.

@_silgen_name("dylibify")
private func c_dylibify(_ macho: UnsafePointer<CChar>,
                        _ saveto: UnsafePointer<CChar>) -> Int32

@_silgen_name("macho_set_maccatalyst_build_version")
private func c_setMacCatalystBuildVersion(_ path: UnsafePointer<CChar>,
                                          _ minosX: UInt32, _ minosY: UInt32,
                                          _ sdkX: UInt32, _ sdkY: UInt32) -> Int32

@_silgen_name("strip_xattrs_recursive")
private func c_stripXattrsRecursive(_ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("macho_is_loadable_image")
private func c_machoIsLoadableImage(_ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("macho_add_rpath")
private func c_machoAddRpath(_ path: UnsafePointer<CChar>,
                             _ rpath: UnsafePointer<CChar>) -> Int32

@_silgen_name("SetGuestWindowScene")
private func c_SetGuestWindowScene(_ scene: UnsafeRawPointer)

@_silgen_name("SetGuestPlaceholderWindow")
private func c_SetGuestPlaceholderWindow(_ window: UnsafeRawPointer)

@_silgen_name("GuestAdoptSceneLessWindows")
private func c_GuestAdoptSceneLessWindows() -> UnsafeRawPointer?

// MARK: - App / Scene Delegates

@objc(LauncherAppDelegate)
final class LauncherAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = LauncherSceneDelegate.self
        return config
    }
}

@objc(SceneDelegate)
final class LauncherSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: LauncherView())
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Scene delegate installed on guest bundles via the `UIApplicationSceneManifest`
/// injected at conversion time. Catalyst requires the scene lifecycle, so when a
/// (typically non-scene) iOS guest calls `UIApplicationMain` it must still wind up
/// inside a real `UIWindowScene`.
///
/// The guest's own app delegate creates its window the legacy way (an orphan
/// `UIWindow` with no scene). Our `makeKeyAndVisible` interposition
/// (`WindowHooks.m`) attaches that window to *this* scene, so whatever the guest
/// added — root view controller or bare subviews — renders. This delegate just
/// registers the scene and removes its own placeholder once a guest window shows.
@objc(GuestSceneDelegate)
final class GuestSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Hand the scene to the window hook so guest windows attach to it.
        c_SetGuestWindowScene(Unmanaged.passUnretained(windowScene).toOpaque())

        // The guest's own window may have been created *before* this scene
        // connected (scene-lifecycle race). Adopt it; only fall back to a blank
        // placeholder if no guest window exists yet.
        let adoptedRaw = c_GuestAdoptSceneLessWindows()
        if let adoptedRaw {
            let guest = Unmanaged<UIWindow>.fromOpaque(adoptedRaw).takeUnretainedValue()
            guest.makeKeyAndVisible()
            self.window = guest
            NSLog("GuestSceneDelegate adopted existing guest window %@", guest)
            return
        }

        let host = UIWindow(windowScene: windowScene)
        host.makeKeyAndVisible()
        self.window = host
        c_SetGuestPlaceholderWindow(Unmanaged.passUnretained(host).toOpaque())
        NSLog("GuestSceneDelegate set placeholder %@", host)

        // Diagnostic: dump window state a couple seconds later to see whether
        // the guest ever produces its own window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let windows = UIApplication.shared.windows
            NSLog("[diag] windows(%ld): %@", windows.count,
                  windows.map { "\($0) scene=\(String(describing: $0.windowScene)) root=\(String(describing: $0.rootViewController)) subs=\($0.subviews.count)" })
        }
    }
}

// MARK: - Paths

enum LauncherPaths {
    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
    static var appsDirectory: URL {
        home.appendingPathComponent("apps", isDirectory: true)
    }
    static var appToLaunchFile: URL {
        home.appendingPathComponent("app_to_launch.txt")
    }
    /// Queue of pending launch requests. Each request is a `<uuid>.txt` file
    /// containing a bundle name; a freshly-spawned instance atomically claims
    /// one in `main.m` before UIKit starts.
    static var pendingLaunchDirectory: URL {
        home.appendingPathComponent("pending_launch", isDirectory: true)
    }
}

// MARK: - Model

struct InstalledApp: Identifiable, Hashable {
    let id: String                  // e.g. "Foo.app"
    let url: URL
    let displayName: String
    let bundleIdentifier: String?
    let version: String?
    let iconPath: String?
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var isWorking: Bool = false
    @Published var status: String = ""
    @Published var errorMessage: String?
    @Published var currentSelection: String?

    func reload() {
        ensureAppsDirectory()
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: LauncherPaths.appsDirectory,
                                                    includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let result: [InstalledApp] = contents.compactMap { url in
            guard url.pathExtension.lowercased() == "app",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let plist = readInfoPlist(at: url) ?? [:]
            let name = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return InstalledApp(
                id: url.lastPathComponent,
                url: url,
                displayName: name,
                bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                version: plist["CFBundleShortVersionString"] as? String,
                iconPath: findIcon(in: url, plist: plist)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        apps = result
        currentSelection = readSelection()
    }

    func importIPA(_ url: URL) async {
        isWorking = true
        status = "Importing \(url.lastPathComponent)…"
        errorMessage = nil
        defer {
            isWorking = false
            reload()
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            ensureAppsDirectory()
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }

            try await Task.detached(priority: .userInitiated) {
                try ZipExtractor.extract(zipURL: url, to: scratch)
            }.value

            let payload = scratch.appendingPathComponent("Payload", isDirectory: true)
            guard fm.fileExists(atPath: payload.path) else {
                throw ImportError.missingPayload
            }
            let payloadContents = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            guard let bundle = payloadContents.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                throw ImportError.missingAppBundle
            }

            let destination = LauncherPaths.appsDirectory.appendingPathComponent(bundle.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: bundle, to: destination)

            status = "Converting \(destination.lastPathComponent)…"
            try await Task.detached(priority: .userInitiated) {
                try AppConverter.convert(bundleURL: destination)
            }.value

            status = "Imported \(destination.lastPathComponent)"
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            status = ""
        }
    }

    func delete(_ app: InstalledApp) {
        do {
            try FileManager.default.removeItem(at: app.url)
            if currentSelection == app.id {
                try? FileManager.default.removeItem(at: LauncherPaths.appToLaunchFile)
            }
            status = "Removed \(app.displayName)"
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        reload()
    }

    /// Launches the guest in its own native window by spawning a fresh instance
    /// of the host. The selection is passed through a queue file rather than
    /// argv: a sandboxed Catalyst app cannot pass launch arguments through
    /// `open` (LaunchServices strips them), so `main.m` atomically claims the
    /// queued request before any UIKit/CFBundle state is locked in.
    func launch(_ app: InstalledApp) {
        do {
            let dir = LauncherPaths.pendingLaunchDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let request = dir.appendingPathComponent(UUID().uuidString + ".txt")
            try app.id.write(to: request, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to queue launch: \(error.localizedDescription)"
            return
        }

        let args = ["/usr/bin/open", "-n", Bundle.main.bundlePath]
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let rc = posix_spawn(&pid, args[0], nil, nil, &argv, environ)
        for case let p? in argv { free(p) }

        if rc == 0 {
            status = "Launched \(app.displayName) in a new window"
        } else {
            errorMessage = "Failed to launch \(app.displayName) (open rc=\(rc))."
        }
    }

    func clearSelection() {
        try? FileManager.default.removeItem(at: LauncherPaths.appToLaunchFile)
        reload()
    }

    // MARK: - Helpers

    private func ensureAppsDirectory() {
        try? FileManager.default.createDirectory(at: LauncherPaths.appsDirectory,
                                                 withIntermediateDirectories: true)
    }

    private func readSelection() -> String? {
        guard let raw = try? String(contentsOf: LauncherPaths.appToLaunchFile, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readInfoPlist(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                     options: [],
                                                                     format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private func findIcon(in appURL: URL, plist: [String: Any]) -> String? {
        // Try Info.plist hints first
        var candidates: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            candidates.append(contentsOf: files)
        }
        if let name = plist["CFBundleIconFile"] as? String {
            candidates.append(name)
        }
        let fm = FileManager.default
        let bundleNames = (try? fm.contentsOfDirectory(atPath: appURL.path)) ?? []

        // Look for filename variants matching any of the candidates
        for base in candidates {
            let matches = bundleNames.filter { name in
                let lower = name.lowercased()
                let baseLower = base.lowercased()
                return (lower.hasPrefix(baseLower) || lower.contains(baseLower)) && lower.hasSuffix(".png")
            }
            if let first = matches.sorted().first {
                return appURL.appendingPathComponent(first).path
            }
        }

        // Fallback: any AppIcon*.png at the bundle root
        let fallback = bundleNames.filter {
            let lower = $0.lowercased()
            return lower.hasSuffix(".png") && (lower.contains("appicon") || lower.hasPrefix("icon"))
        }
        if let first = fallback.sorted().first {
            return appURL.appendingPathComponent(first).path
        }
        return nil
    }
}

enum ImportError: LocalizedError {
    case missingPayload
    case missingAppBundle

    var errorDescription: String? {
        switch self {
        case .missingPayload: return "IPA is missing the Payload directory."
        case .missingAppBundle: return "IPA does not contain a .app bundle."
        }
    }
}

// MARK: - View

struct LauncherView: View {
    @StateObject private var model = LauncherModel()
    @State private var pendingApp: InstalledApp?
    @State private var showImporter = false

    var body: some View {
        NavigationView {
            List {
                if let selection = model.currentSelection {
                    Section("Current selection") {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text(selection)
                            Spacer()
                            Button("Clear") { model.clearSelection() }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Installed apps") {
                    if model.apps.isEmpty {
                        Text("No apps installed yet.\nTap the import button to add an IPA.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(model.apps) { app in
                            Button { pendingApp = app } label: {
                                AppRow(app: app)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet { model.delete(model.apps[index]) }
                        }
                    }
                }

                if model.isWorking || !model.status.isEmpty {
                    Section("Status") {
                        HStack {
                            if model.isWorking { ProgressView() }
                            Text(model.status).font(.callout)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("iOS App Loader")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import IPA", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.isWorking)
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType.ipa],
                          allowsMultipleSelection: false) { result in
                guard let url = try? result.get().first else { return }
                Task { await model.importIPA(url) }
            }
            .confirmationDialog(
                pendingApp.map { "Launch \($0.displayName)?" } ?? "",
                isPresented: Binding(
                    get: { pendingApp != nil },
                    set: { if !$0 { pendingApp = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let app = pendingApp {
                    Button("Launch") { model.launch(app) }
                    Button("Delete", role: .destructive) {
                        model.delete(app)
                        pendingApp = nil
                    }
                    Button("Cancel", role: .cancel) { pendingApp = nil }
                }
            } message: {
                Text("The app opens in a new window. The launcher stays open.")
            }
            .alert("Error",
                   isPresented: Binding(
                       get: { model.errorMessage != nil },
                       set: { if !$0 { model.errorMessage = nil } }
                   )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .navigationViewStyle(.stack)
        .task { model.reload() }
    }
}

private struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)
                if let bid = app.bundleIdentifier {
                    Text(bid)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let version = app.version {
                Text(version)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Image(systemName: "play.circle.fill")
                .foregroundColor(.accentColor)
                .imageScale(.large)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconView: some View {
        if let iconPath = app.iconPath,
           let image = UIImage(contentsOfFile: iconPath) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.gray.opacity(0.25))
                Image(systemName: "app.fill")
                    .foregroundColor(.gray)
            }
        }
    }
}

private extension UTType {
    static let ipa: UTType = {
        if let type = UTType(filenameExtension: "ipa") { return type }
        return .data
    }()
}
// MARK: - Install-time conversion (replaces convert.sh)

enum ConversionError: LocalizedError {
    case missingExecutableName
    case dylibifyFailed(Int32)
    case replaceExecutableFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingExecutableName:
            return "Could not determine CFBundleExecutable from the bundle's Info.plist."
        case .dylibifyFailed(let code):
            return "dylibify failed (rc=\(code))."
        case .replaceExecutableFailed(let err):
            return "Failed to swap the dylibified executable in: \(err.localizedDescription)"
        }
    }
}

enum AppConverter {
    /// Mirrors `convert.sh`:
    ///   1. dylibify the main executable
    ///   2. strip extended attributes recursively
    ///   3. (Mac Catalyst only) rewrite LC_BUILD_VERSION to macCatalyst 11.0 / 14.0
    ///      for the main exec, each embedded .framework, and each .dylib
    ///
    /// The ad-hoc codesign step from the script is intentionally omitted: the
    /// host installs `hooked_mmap`/`hooked___fcntl` in LCDyld.m, which let
    /// dyld load unsigned binaries via anonymous RWX mappings (the
    /// `RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY` entitlement
    /// permits this).
    static func convert(bundleURL: URL) throws {
        let fm = FileManager.default

        // 1. Find the main executable via Info.plist.
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        var execName: String?
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                   options: [],
                                                                   format: nil) as? [String: Any] {
            execName = plist["CFBundleExecutable"] as? String
        }
        guard let exec = execName, !exec.isEmpty else {
            throw ConversionError.missingExecutableName
        }
        let execURL = bundleURL.appendingPathComponent(exec)

        // 2. dylibify into a sibling temp path, then atomically swap.
        let tmpURL = bundleURL.appendingPathComponent(exec + ".dylibified")
        try? fm.removeItem(at: tmpURL)
        let rc = execURL.path.withCString { src in
            tmpURL.path.withCString { dst in
                c_dylibify(src, dst)
            }
        }
        guard rc == 0 else { throw ConversionError.dylibifyFailed(rc) }

        do {
            let originalMode = (try? fm.attributesOfItem(atPath: execURL.path))?[.posixPermissions]
            try fm.removeItem(at: execURL)
            try fm.moveItem(at: tmpURL, to: execURL)
            let mode = (originalMode as? NSNumber) ?? NSNumber(value: 0o755)
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: execURL.path)
        } catch {
            throw ConversionError.replaceExecutableFailed(error)
        }

        // 3. xattr -cr equivalent.
        _ = bundleURL.path.withCString { c_stripXattrsRecursive($0) }

        // 3b. Catalyst requires the UIKit scene lifecycle. Old iOS guests call
        // UIApplicationMain with the host's main bundle redirected to theirs, so
        // their Info.plist must carry a scene manifest or UIApplicationMain aborts.
        injectSceneManifest(in: bundleURL)

        // 4. Mac Catalyst-only build-version retargeting.
        if ProcessInfo.processInfo.isMacCatalystApp {
            retargetAllMachOImages(in: bundleURL)
        }
    }

    /// Rewrites the guest's Info.plist to advertise a scene-based lifecycle,
    /// wiring every application-scene role to the host's `GuestSceneDelegate`.
    private static func injectSceneManifest(in bundleURL: URL) {
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil)) as? [String: Any] else {
            return
        }

        var manifest = (plist["UIApplicationSceneManifest"] as? [String: Any]) ?? [:]
        var configs = (manifest["UISceneConfigurations"] as? [String: Any]) ?? [:]
        configs["UIWindowSceneSessionRoleApplication"] = [[
            "UISceneConfigurationName": "Default Configuration",
            "UISceneDelegateClassName": "GuestSceneDelegate",
        ]]
        manifest["UISceneConfigurations"] = configs
        manifest["UIApplicationSupportsMultipleScenes"] = false
        plist["UIApplicationSceneManifest"] = manifest

        if let out = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .binary,
                                                         options: 0) {
            try? out.write(to: plistURL, options: [.atomic])
        }
    }

    /// Recursively walks the whole app bundle and retargets every Mach-O image
    /// (frameworks, .dylibs, loadable bundles, and the dylibified main
    /// executable) to Mac Catalyst.
    ///
    /// Images are identified by inspecting their Mach-O header rather than by
    /// trusting the bundle layout or file extensions, so binaries dyld would
    /// otherwise reject are caught wherever they live — Frameworks/,
    /// PlugIns/*.appex, nested frameworks, loadable .bundles, and
    /// extension-less helpers alike.
    private static func retargetAllMachOImages(in bundleURL: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let isImage = fileURL.path.withCString { c_machoIsLoadableImage($0) } != 0
            guard isImage else { continue }
            retargetToMacCatalyst(at: fileURL)
            injectSwiftRpath(at: fileURL)
        }
    }

    // Catalyst hosts all the iOS Swift runtime overlays in the dyld cache
    // under /System/iOSSupport/usr/lib/swift. Guest Swift frameworks link them
    // via @rpath/libswift*.dylib, but their own rpaths don't reach that
    // directory, so dyld can't bind them when we dlopen the guest. Add the
    // iOS-support Swift dir as an LC_RPATH so those references resolve.
    private static func injectSwiftRpath(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let rpath = "/System/iOSSupport/usr/lib/swift"
        let rc = url.path.withCString { p in
            rpath.withCString { c_machoAddRpath(p, $0) }
        }
        if rc < 0 {
            NSLog("[converter] failed to add Swift rpath on %@", url.path as NSString)
        }
    }

    private static func retargetToMacCatalyst(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let rc = url.path.withCString {
            c_setMacCatalystBuildVersion($0, 11, 0, 14, 0)
        }
        if rc < 0 {
            NSLog("[converter] failed to set build version on %@", url.path as NSString)
        }
    }
}

