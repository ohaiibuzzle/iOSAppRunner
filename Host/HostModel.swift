//
//  HostModel.swift
//  BaseiOSAppHost
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct InstalledApp: Identifiable, Hashable {
    let id: String                  // e.g. "com.foo.Bar.app"
    let url: URL
    let displayName: String
    let bundleIdentifier: String?
    let version: String?
    let iconPath: String?
}

@MainActor
final class HostModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var isWorking: Bool = false
    @Published var status: String = ""
    @Published var errorMessage: String?

    /// List selection (drives the Guest menu commands).
    @Published var selection: InstalledApp?

    // UI state shared between the window and the menu-bar commands.
    @Published var pendingImportURLs: [URL]?
    @Published var compatSheetApp: InstalledApp?
    @Published var deleteConfirmApp: InstalledApp?
    @Published var keychainResetConfirmApp: InstalledApp?
    @Published var confirmKeychainReset: Bool = false

    /// Cached per-app render data (runtime mode + icon). Refreshed off the
    /// main thread in reload(); keyed by install name (InstalledApp.id).
    @Published var runtimeModes: [String: RuntimeMode] = [:]
    @Published var icons: [String: NSImage] = [:]

    /// Reveals a runtime's container Data folder in Finder, falling back to
    /// the nearest existing ancestor.
    func revealRuntimeHome(_ flavor: RuntimeFlavor) {
        var url = GuestPaths.containerDirectory(for: flavor)
        let fm = FileManager.default
        while url.path != "/", !fm.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent()
        }
        NSWorkspace.shared.open(url)
    }

    /// DEBUG: BASEIOSAPP_AUTOLAUNCH=<install name> fires one launch after
    /// startup, for headless launcher debugging.
    private var autoLaunchDone = false

    func reload() {
        GuestPaths.ensureAppsDirectory()
        primeRuntimeContainersIfNeeded()
        Task {
            let scan = await Task.detached(priority: .userInitiated) {
                // One-time legacy-container move; idempotent.
                GuestStore.migrateLegacyIfNeeded()
                return Self.scanApps()
            }.value
            apps = scan.apps
            runtimeModes = scan.runtimeModes
            icons = scan.icons
            autoLaunchIfNeeded()
            // Drop a stale selection if its app vanished.
            if let sel = selection, !scan.apps.contains(where: { $0.id == sel.id }) {
                selection = nil
            }
        }
    }

    /// Once per session in the background: register the headless iOS runtime
    /// so containermanagerd assigns its UUID-named container before any
    /// guest is placed or migrated. The Catalyst container needs no
    /// registration.
    private var primedContainersThisSession = false

    private func primeRuntimeContainersIfNeeded() {
        guard !primedContainersThisSession else { return }
        primedContainersThisSession = true
        Task.detached(priority: .utility) { [weak self] in
            guard RuntimeLauncher.ensureIOSRuntimeContainer() else { return }
            // Refresh: the scan may predate the priming.
            await MainActor.run { [weak self] in self?.reload() }
        }
    }

    /// Result of the off-main-thread directory scan in scanApps().
    private struct AppScan {
        var apps: [InstalledApp] = []
        var runtimeModes: [String: RuntimeMode] = [:]
        var icons: [String: NSImage] = [:]
    }

    /// Directory scan + plist reads + icon loading, off the main thread.
    /// Both runtime containers are scanned, deduplicated by install name
    /// (Catalyst wins ties).
    private nonisolated static func scanApps() -> AppScan {
        let fm = FileManager.default
        var contents: [URL] = []
        var seen = Set<String>()
        for flavor in [RuntimeFlavor.catalyst, .ios] {
            let directory = GuestPaths.appsDirectory(for: flavor)
            let entries = (try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for url in entries where !seen.contains(url.lastPathComponent) {
                seen.insert(url.lastPathComponent)
                contents.append(url)
            }
        }
        var result: [InstalledApp] = []
        var modes: [String: RuntimeMode] = [:]
        var icons: [String: NSImage] = [:]
        for url in contents {
            guard url.pathExtension.lowercased() == "app",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let plist = GuestStore.readInfoPlist(at: url) ?? [:]
            let name = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let app = InstalledApp(
                id: url.lastPathComponent,
                url: url,
                displayName: name,
                bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                version: plist["CFBundleShortVersionString"] as? String,
                iconPath: findIcon(in: url, plist: plist)
            )
            result.append(app)
            GuestStore.enforceRequiredFeatures(for: url)
            modes[app.id] = GuestStore.runtimeMode(for: url)
            if let iconPath = app.iconPath {
                icons[app.id] = NSImage(contentsOfFile: iconPath)
            }
        }
        result.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return AppScan(apps: result, runtimeModes: modes, icons: icons)
    }

    /// DEBUG: launches BASEIOSAPP_AUTOLAUNCH shortly after the first reload.
    private func autoLaunchIfNeeded() {
        guard !autoLaunchDone,
              let requested = ProcessInfo.processInfo.environment["BASEIOSAPP_AUTOLAUNCH"],
              !requested.isEmpty else { return }
        autoLaunchDone = true
        NSLog("[autolaunch] requested=%@ installed=%@", requested as NSString,
              apps.map(\.id).joined(separator: ", ") as NSString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard let target = self.apps.first(where: { $0.id == requested }) else {
                NSLog("[autolaunch] no app named %@", requested as NSString)
                return
            }
            NSLog("[autolaunch] launching %@", target.id as NSString)
            self.launch(target)
        }
    }

    /// Opens the standard open panel (⌘O / toolbar) and stages the picked
    /// IPAs for the import-options sheet.
    func pickAndImportIPAs() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import IPAs")
        panel.allowedContentTypes = [.ipaType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let self, !panel.urls.isEmpty else { return }
            self.pendingImportURLs = panel.urls
        }
    }

    /// Imports a batch of IPAs sequentially; a failed IPA doesn't abort the
    /// batch. Failures are collected and reported in one aggregated error.
    func importIPAs(_ urls: [URL], importFeatures: [String: Bool]) async {
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            reload()
        }

        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            status = String(localized: "Importing \(index + 1) of \(urls.count): \(url.lastPathComponent)…")
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let installed = try await Task.detached(priority: .userInitiated) {
                    try GuestStore.install(from: url, importFeatures: importFeatures)
                }.value
                status = String(localized: "Imported \(installed)")
            } catch {
                failures.append(String(localized: "\(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }

        if failures.isEmpty {
            status = urls.count == 1 ? String(localized: "Imported \(urls[0].lastPathComponent)")
                : String(localized: "Imported \(urls.count) apps")
        } else {
            status = String(localized: "Imported \(urls.count - failures.count) of \(urls.count)")
            errorMessage = String(localized: "Some imports failed:\n\(failures.joined(separator: "\n"))")
        }
    }

    /// Full guest cleanup: guest bundle, data directory, legacy queued
    /// artifacts, and keychain slot (wiped + reclaimed).
    func deleteWithCleanup(_ app: InstalledApp) {
        isWorking = true
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                GuestStore.deleteWithCleanup(bundleID: app.bundleIdentifier, appURL: app.url)
            }.value
            isWorking = false
            status = summary
            reload()
        }
    }

    /// Launches a guest on a background queue (the iOS path blocks in pid
    /// polling for seconds); the launcher reads the mode from the bundle's
    /// actual residence, never a UI-cached URL.
    func launch(_ app: InstalledApp) {
        let installName = app.id
        let bundleID = app.bundleIdentifier

        isWorking = true
        status = String(localized: "Launching \(app.displayName)…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = RuntimeLauncher.launch(installName: installName,
                                                 guestBundleID: bundleID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if outcome.ok {
                    self.status = outcome.message
                } else {
                    self.errorMessage = outcome.message
                }
            }
        }
    }

    // MARK: - Runtime control

    /// Kills every running runtime process (and with it, any guests inside
    /// them), releasing the per-guest `.guest.lock` flocks.
    func killRuntimes() {
        guard !isWorking else { return }
        isWorking = true
        status = String(localized: "Killing runtime processes…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let killed = RuntimeLauncher.killAllRuntimes()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                self.status = killed > 0
                    ? String(localized: "Killed \(killed) runtime process\(killed == 1 ? "" : "es")")
                    : String(localized: "No runtime processes were running")
            }
        }
    }

    // MARK: - Keychain

    /// Per-app keychain reset: deletes the guest's keychain items but keeps
    /// its slot assignment.
    func resetKeychain(for app: InstalledApp) {
        guard let bid = app.bundleIdentifier, !bid.isEmpty else {
            status = String(localized: "No bundle ID; nothing to reset")
            return
        }
        isWorking = true
        status = String(localized: "Resetting \(app.displayName) keychain…")
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                KeychainManager.resetKeychain(bundleID: bid)
            }.value
            isWorking = false
            status = summary
        }
    }

    func resetAllKeychainItems() {
        guard !isWorking else { return }
        isWorking = true
        status = String(localized: "Resetting keychain…")
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                KeychainManager.wipeAllGuestItems()
            }.value
            isWorking = false
            status = summary
        }
    }

    // MARK: - Per-app features (RunnerFeatures.plist)

    func featureEnabled(_ key: String, for app: InstalledApp) -> Bool {
        guard let plist = GuestStore.readRunnerFeatures(for: app.url) else {
            return HostFeature.defaultValues[key] ?? true
        }
        return plist[key] as? Bool ?? (HostFeature.defaultValues[key] ?? true)
    }

    func setFeature(_ key: String, enabled: Bool, for app: InstalledApp) {
        GuestStore.writeRunnerFeatures([key: enabled], for: app.url)
        objectWillChange.send()
    }

    /// Runtime mode for a guest (default Catalyst).
    func runtimeMode(for app: InstalledApp) -> RuntimeMode {
        GuestStore.runtimeMode(for: app.url)
    }

    func setRuntimeMode(_ mode: RuntimeMode, for app: InstalledApp) {
        GuestStore.writeRunnerFeatures(["runtime": mode.rawValue], for: app.url)
        runtimeModes[app.id] = mode
        objectWillChange.send()
    }

    /// Runs when the Compatibility sheet closes: migrates the guest into the
    /// selected runtime's container, keeping launch a pure
    /// spawn-from-residence operation. Fails closed — on migration failure
    /// the stored mode reverts to the residence flavor so the plist never
    /// promises an unlaunchable runtime.
    func applyRuntimeSelection(for app: InstalledApp) {
        let installName = app.id
        let bundleID = app.bundleIdentifier
        isWorking = true
        status = String(localized: "Moving \(app.displayName) between runtime containers…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let located = GuestStore.locateInstalledGuest(installName: installName) else {
                await MainActor.run { [weak self] in
                    self?.isWorking = false
                    self?.errorMessage = String(localized:
                        "Could not find \(installName) in either runtime container.")
                }
                return
            }
            let mode = GuestStore.runtimeMode(for: located.url)
            let target: RuntimeFlavor = mode == .ios ? .ios : .catalyst
            do {
                // Prime first or the migration lands in the stale
                // bundle-ID-named container.
                if target == .ios, !RuntimeLauncher.ensureIOSRuntimeContainer() {
                    throw MigrationError.containerSetupFailed
                }
                try GuestStore.ensureGuestResides(installName: installName,
                                                  guestBundleID: bundleID,
                                                  target: target)
                await MainActor.run { [weak self] in
                    self?.isWorking = false
                    self?.status = String(localized:
                        "\(app.displayName) now resides in the \(target.displayName) runtime container.")
                    self?.reload()
                }
            } catch {
                // Fail closed: revert the plist to the residence flavor so
                // it matches reality again and the app stays launchable.
                let revertMode: RuntimeMode = located.flavor == .ios ? .ios : .catalyst
                GuestStore.writeRunnerFeatures(["runtime": revertMode.rawValue], for: located.url)
                await MainActor.run { [weak self] in
                    self?.isWorking = false
                    self?.runtimeModes[installName] = revertMode
                    self?.errorMessage = error.localizedDescription
                    self?.reload()
                }
            }
        }
    }

    /// String override from the guest's RunnerFeatures.plist ("" when unset).
    func spoofOverride(_ key: String, for app: InstalledApp) -> String {
        guard let plist = GuestStore.readRunnerFeatures(for: app.url),
              let value = plist[key] as? String else { return "" }
        return value
    }

    /// Writes a string override; empty removes the key (hooks fall back to
    /// their built-in default).
    func setSpoofOverride(_ key: String, value: String, for app: InstalledApp) {
        var plist = GuestStore.readRunnerFeatures(for: app.url) ??
            Dictionary(uniqueKeysWithValues: HostFeature.defaultValues.map { ($0, $1) })
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            plist.removeValue(forKey: key)
        } else {
            plist[key] = trimmed
        }
        if let out = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .xml,
                                                         options: 0) {
            try? out.write(to: app.url.appendingPathComponent("RunnerFeatures.plist"))
            objectWillChange.send()
        }
    }

    // MARK: - Helpers

    private nonisolated static func findIcon(in appURL: URL, plist: [String: Any]) -> String? {
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

private extension UTType {
    static let ipaType: UTType = {
        if let type = UTType(filenameExtension: "ipa") { return type }
        return .data
    }()
}
