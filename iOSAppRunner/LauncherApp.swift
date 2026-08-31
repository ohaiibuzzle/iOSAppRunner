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
    /// Written by the launcher (see `writeHostDisplayMetricsFile`) right
    /// before spawning a guest; `Resolution.m` reads it back to size the
    /// guest's fake `UIScreen` to the Mac's real display.
    static var displayResolutionFile: URL {
        home.appendingPathComponent("display_resolution.plist")
    }
}

// MARK: - Host display resolution hand-off
//
// Mac Catalyst doesn't expose AppKit headers, but the process is a real
// AppKit app under the hood, so NSWindow/NSScreen are reachable via the
// Objective-C runtime (the same bridge PlayCover uses). We measure from the
// launcher's own live window — already fully laid out by the system, so far
// more reliable than trying to bridge AppKit from inside a freshly-hooked
// guest process — and persist the result to a file the guest reads at
// launch, the same hand-off used for queuing which app to launch.

private extension UIWindow {
    /// The real AppKit `NSWindow` backing this Catalyst `UIWindow`.
    var hostNSWindow: NSObject? {
        guard let nsWindows = NSClassFromString("NSApplication")?
            .value(forKeyPath: "sharedApplication.windows") as? [AnyObject] else { return nil }
        for nsWindow in nsWindows {
            let uiWindows = nsWindow.value(forKeyPath: "uiWindows") as? [UIWindow] ?? []
            if uiWindows.contains(self) {
                return nsWindow as? NSObject
            }
        }
        return nil
    }
}

private struct HostDisplayMetrics: Codable {
    let width: Double   // points, content area only (title bar excluded) — for UIScreen.bounds
    let height: Double
    let scale: Double
    // AppKit screen-space outer window frame (title bar + content), for
    // requestGeometryUpdateWithPreferences: — sizeRestrictions alone only
    // *bounds* a window, it doesn't move/resize one Mac Catalyst already
    // placed via its own frame restoration (e.g. the launcher's last frame).
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double
}

private func measureHostDisplayMetrics() -> HostDisplayMetrics? {
    guard
        let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first,
        let nsWindow = window.hostNSWindow,
        let screen = nsWindow.value(forKey: "screen") as? NSObject,
        let visibleFrameValue = screen.value(forKey: "visibleFrame") as? NSValue,
        let scaleNumber = screen.value(forKey: "backingScaleFactor") as? NSNumber
    else {
        return nil
    }

    // visibleFrame excludes the menu bar and Dock — the actual space a
    // maximized window can occupy, unlike the screen's raw full frame.
    var visibleFrame = CGRect.zero
    visibleFrameValue.getValue(&visibleFrame)

    // Mac Catalyst windows use a full-size content view internally — the
    // title bar floats over the content instead of reserving its own space,
    // so `NSWindow.contentView.frame` is identical to `NSWindow.frame` and
    // can't be diffed to find the title bar height. UIKit surfaces it as a
    // safe area inset instead, which is what we actually want here anyway.
    let titleBarHeight = window.safeAreaInsets.top
    let contentHeight = visibleFrame.height - titleBarHeight
    return HostDisplayMetrics(
        width: visibleFrame.width,
        height: contentHeight,
        scale: scaleNumber.doubleValue,
        frameX: visibleFrame.origin.x,
        frameY: visibleFrame.origin.y,
        frameWidth: visibleFrame.width,
        frameHeight: visibleFrame.height
    )
}

private func writeHostDisplayMetricsFile() {
    guard let metrics = measureHostDisplayMetrics(),
          let data = try? PropertyListEncoder().encode(metrics) else {
        return
    }
    try? data.write(to: LauncherPaths.displayResolutionFile)
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

/// The per-app host hooks. `all` are **runtime-toggleable** — edited after import
/// from the "Compatibility Settings" sheet, and read at launch by `Loader`
struct Feature: Identifiable {
    let id: String
    let name: String
    let detail: String

    /// Runtime-toggleable hooks shown in the Compatibility Settings sheet.
    static let all: [Feature] = [
        Feature(id: "groupContainer", name: "Group containers",
                detail: "Redirect security-application-group URLs into the guest home."),
        Feature(id: "resolution", name: "Spoof display resolution",
                detail: "Fake UIScreen to match the Mac's display and lock the window size (unless the app supports resizing)."),
        Feature(id: "keychain", name: "Keychain remap",
                detail: "Remap keychain access groups to the host's team ID."),
        Feature(id: "sceneLifecycleHooks", name: "Scene-lifecycle abort bypass",
                detail: "Prevent Catalyst from fatally terminating guests that have no scene manifest."),
    ]

    /// Import-time-only toggles, shown as toggles in the Import sheet. Add any
    /// future convert-time features here.
    static let importOnly: [Feature] = [
        Feature(id: "scene", name: "UIScene compatibility fix",
                detail: "Inject a scene manifest for legacy apps that uses the legacy UIScene lifecycle."),
    ]

    /// Default enabled-state per feature. `scene` (import-time) is default-OFF;
    /// runtime hooks default ON. Keep in sync with `writeDefaultRunnerFeatures`
    /// and `Loader.h`.
    static let defaultValues: [String: Bool] = [
        "scene": false,
        "groupContainer": true,
        "resolution": true,
        "keychain": true,
        "sceneLifecycleHooks": true,
    ]
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

    func importIPA(_ url: URL, importFeatures: [String: Bool]) async {
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
                try AppConverter.convert(bundleURL: destination, importFeatures: importFeatures)
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
        writeHostDisplayMetricsFile()
        do {
            let dir = LauncherPaths.pendingLaunchDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let request = dir.appendingPathComponent(UUID().uuidString + ".txt")
            try app.id.write(to: request, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to queue launch: \(error.localizedDescription)"
            return
        }
#if targetEnvironment(macCatalyst)
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
#else
        exit(0)
#endif
    }

    func clearSelection() {
        try? FileManager.default.removeItem(at: LauncherPaths.appToLaunchFile)
        reload()
    }

    // MARK: - Per-app features (RunnerFeatures.plist)

    func featureEnabled(_ key: String, for app: InstalledApp) -> Bool {
        guard let plist = readRunnerFeatures(for: app.url) else {
            return Feature.defaultValues[key] ?? true
        }
        return plist[key] as? Bool ?? (Feature.defaultValues[key] ?? true)
    }

    func setFeature(_ key: String, enabled: Bool, for app: InstalledApp) {
        var plist = readRunnerFeatures(for: app.url)
            ?? Dictionary(uniqueKeysWithValues: Feature.defaultValues.map { ($0, $1) })
        plist[key] = enabled
        if let out = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .xml,
                                                         options: 0) {
            try? out.write(to: app.url.appendingPathComponent("RunnerFeatures.plist"))
        }
    }

    private func readRunnerFeatures(for appURL: URL) -> [String: Any]? {
        let url = appURL.appendingPathComponent("RunnerFeatures.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil) as? [String: Any] else {
            return nil
        }
        return plist
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
    @State private var compatApp: InstalledApp?
    @State private var showImporter = false
    @State private var pendingImport: URL?
    @State private var showImportSheet = false

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
            .navigationTitle("iOSAppRunner")
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
                // Convert-time feature decisions (e.g. scene manifest injection)
                // are made here, in the Import sheet, because they're baked into
                // the converted bundle and can't change without a re-import.
                pendingImport = url
                showImportSheet = true
            }
            .sheet(isPresented: $showImportSheet, onDismiss: { pendingImport = nil }) {
                if let url = pendingImport {
                    ImportOptionsView(url: url, model: model)
                }
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
#if targetEnvironment(macCatalyst)
                    Button("Launch") { model.launch(app) }
#else
                    Button("Exit and Queue Launch") { model.launch(app) }
#endif
                    Button("Compatibility Settings…") {
                        compatApp = app
                        pendingApp = nil
                    }
                    Button("Delete", role: .destructive) {
                        model.delete(app)
                        pendingApp = nil
                    }
                    Button("Cancel", role: .cancel) { pendingApp = nil }
                }
            }
            .sheet(item: $compatApp) { app in
                CompatSettingsView(app: app, model: model)
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

/// Import confirmation / options sheet, shown after picking an IPA. Lists the
/// convert-time-only feature toggles (e.g. `scene`) as switches, so decisions
/// baked into the converted bundle are made here rather than after the fact.
private struct ImportOptionsView: View {
    let url: URL
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: [String: Bool] = [:]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(Feature.importOnly) { feature in
                        Toggle(isOn: Binding(
                            get: { enabled[feature.id] ?? (Feature.defaultValues[feature.id] ?? false) },
                            set: { enabled[feature.id] = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.name)
                                Text(feature.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import app")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task {
                            await model.importIPA(url, importFeatures: enabled)
                        }
                        dismiss()
                    }
                    .disabled(model.isWorking)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Per-app compatibility toggle sheet. Edits the guest's `RunnerFeatures.plist`;
/// `main.m`'s `Loader` consults it at launch to decide which host hooks run for
/// this specific guest (so a fix can be scoped to one app without affecting others).
private struct CompatSettingsView: View {
    let app: InstalledApp
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(Feature.all) { feature in
                        Toggle(isOn: Binding(
                            get: { model.featureEnabled(feature.id, for: app) },
                            set: { model.setFeature(feature.id, enabled: $0, for: app) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.name)
                                Text(feature.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Runtime hooks can be used to mitigate issues with the guest app.")
                }
            }
            .navigationTitle("Compatibility — \(app.displayName)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        for feature in Feature.all {
                            model.setFeature(feature.id, enabled: Feature.defaultValues[feature.id] ?? true, for: app)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
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
    static func convert(bundleURL: URL, importFeatures: [String: Bool]) throws {
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

        // 3a. Write the per-app feature manifest. `importFeatures` holds the
        // convert-time decisions chosen in the Import sheet (e.g. `scene`, default
        // OFF); the runtime hooks default ON and stay toggleable. The launcher's
        // "Compatibility Settings" sheet edits the runtime keys; main.m gates each
        // hook init on them.
        writeDefaultRunnerFeatures(in: bundleURL, importFeatures: importFeatures)

        // 3b. Catalyst requires the UIKit scene lifecycle. Old iOS guests call
        // UIApplicationMain with the host's main bundle redirected to theirs, so
        // their Info.plist must carry a scene manifest or UIApplicationMain aborts.
        // Scene-native guests that already ship a manifest keep their own delegate.
        injectSceneManifest(in: bundleURL)

        // 4. Mac Catalyst-only build-version retargeting.
        if ProcessInfo.processInfo.isMacCatalystApp {
            retargetAllMachOImages(in: bundleURL)
        }
    }

    /// Writes a default `RunnerFeatures.plist` (every hook enabled) so a
    /// freshly-imported guest behaves like a legacy host install. The launcher
    /// edits it per-app; `main.m` (via `Loader`) gates each hook init on it.
    ///
    /// An existing manifest is **preserved** (defaults fill in missing keys
    /// only), so a user's per-app toggles survive a re-import / re-convert.
    private static func writeDefaultRunnerFeatures(in bundleURL: URL, importFeatures: [String: Bool]) {
        let featuresURL = bundleURL.appendingPathComponent("RunnerFeatures.plist")
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: featuresURL),
           let existing = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil) as? [String: Any] {
            dict = existing
        }
        // Import-time features come from the Import sheet; they are convert-time
        // decisions, not runtime toggles.
        for (key, value) in importFeatures {
            dict[key] = value
        }
        for (key, value) in Feature.defaultValues where dict[key] == nil {
            dict[key] = value
        }
        if let out = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                         format: .xml,
                                                         options: 0) {
            try? out.write(to: featuresURL)
        }
    }

    /// Rewrites the guest's Info.plist so UIKit can connect a scene under
    /// Catalyst.
    ///
    /// The old implementation *unconditionally* overwrote
    /// `UIWindowSceneSessionRoleApplication` with the host's `GuestSceneDelegate`,
    /// which clobbers a scene-native guest's own SceneDelegate (e.g.
    /// Aidoku's `Aidoku.SceneDelegate` → `TabBarController` window), leaving it
    /// blank. We now preserve a guest's existing application-role scene config
    /// and only fall back to `GuestSceneDelegate` when the guest ships none.
    ///
    /// Honours the per-app `scene` feature (RunnerFeatures.plist): when a guest
    /// has `scene` disabled, the Info.plist is left byte-for-byte untouched here
    /// (no manifest injected, no `UIApplicationSupportsMultipleScenes` forced),
    /// so the guest runs with its own scene configuration or none at all.
    private static func injectSceneManifest(in bundleURL: URL) {
        let featuresURL = bundleURL.appendingPathComponent("RunnerFeatures.plist")
        if let featureData = try? Data(contentsOf: featuresURL),
           let featurePlist = try? PropertyListSerialization.propertyList(from: featureData,
                                                                          options: [],
                                                                          format: nil) as? [String: Any],
           featurePlist["scene"] as? Bool == false {
            NSLog("[converter] scene disabled for %@ — leaving scene manifest untouched", bundleURL.lastPathComponent)
            return
        }

        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil)) as? [String: Any] else {
            return
        }

        var manifest = (plist["UIApplicationSceneManifest"] as? [String: Any]) ?? [:]
        var configs = (manifest["UISceneConfigurations"] as? [String: Any]) ?? [:]
        let roleConfigs = (configs["UIWindowSceneSessionRoleApplication"] as? [[String: Any]]) ?? []
        if roleConfigs.isEmpty {
            // Legacy guest with no scene lifecycle shipped its own delegate:
            // point the application role at the host's GuestSceneDelegate so a
            // scene actually connects (Catalyst aborts otherwise).
            configs["UIWindowSceneSessionRoleApplication"] = [[
                "UISceneConfigurationName": "Default Configuration",
                "UISceneDelegateClassName": "GuestSceneDelegate",
            ]]
        }
        // else: scene-native guest already wires its own delegate — preserve it.
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

