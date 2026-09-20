//
//  HostApp.swift
//  BaseiOSAppHost
//
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Feature configuration (shared with the runtime's Loader)

/// The per-app hooks. `all` are **runtime-toggleable** — edited after import
/// from the Compatibility sheet, and read at launch by the runtime's Loader.
struct HostFeature: Identifiable {
    let id: String
    let name: String
    let detail: String

    /// Runtime-toggleable hooks shown in the Compatibility Settings sheet.
    /// Keys must match the `LoaderFeature*` constants in Runtime/Loader.h.
    static let all: [HostFeature] = [
        HostFeature(id: "resolution", name: String(localized: "Spoof display resolution"),
                    detail: String(localized: "Fake UIScreen to match the Mac's display and lock the window size (unless the app supports resizing).")),
        HostFeature(id: "deviceSpoof", name: String(localized: "Spoof device (sysctl)"),
                    detail: String(localized: "Report an iPad to apps that check hw.machine / hw.model via sysctl.")),
    ]

    /// Import-time-only toggles, shown in the Import sheet. Add any future
    /// convert-time features here.
    static let importOnly: [HostFeature] = [
        HostFeature(id: "scene", name: String(localized: "UIScene compatibility fix"),
                    detail: String(localized: "Inject a scene manifest for legacy apps that uses the legacy UIScene lifecycle.")),
    ]

    /// Default enabled-state per feature. `scene` (import-time) is default-OFF;
    /// runtime hooks default ON. Keep in sync with GuestStore's conversion
    /// defaults and Runtime/Loader.h.
    static let defaultValues: [String: Bool] = [
        "scene": false,
        "groupContainer": true,
        "resolution": true,
        "keychain": true,
        "deviceSpoof": true,
    ]
}

/// Device-spoofing configuration shared between the host UI and the runtime
/// hooks. Keys are written into the guest's RunnerFeatures.plist; keep in
/// sync with the `LoaderSpoofKey*` constants in Runtime/Loader.h.
enum DeviceSpoofConfig {
    static let machineKey = "spoofDeviceMachine"   // hw.machine
    static let modelKey = "spoofDeviceModel"       // hw.model
    static let osVersionKey = "spoofDeviceOSVersion" // kern.osproductversion

    /// Built-in fallbacks used by the hooks when an override is empty.
    static let defaultMachine = "iPad14,6"
    static let defaultModel = "iPad14,6"
}

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

    func reload() {
        GuestPaths.ensureAppsDirectory()
        Task {
            let scan = await Task.detached(priority: .userInitiated) {
                Self.scanApps()
            }.value
            apps = scan.apps
            runtimeModes = scan.runtimeModes
            icons = scan.icons
            // Drop a stale selection if its app vanished.
            if let sel = selection, !scan.apps.contains(where: { $0.id == sel.id }) {
                selection = nil
            }
        }
    }

    /// Directory scan + plist reads + icon loading. Runs OFF the main thread;
    /// the result is published on the main actor by reload().
    private nonisolated static func scanApps() -> (
        apps: [InstalledApp], runtimeModes: [String: RuntimeMode], icons: [String: NSImage]
    ) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: GuestPaths.appsDirectory,
                                                    includingPropertiesForKeys: [.isDirectoryKey])) ?? []
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
        return (result, modes, icons)
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

    /// Imports a batch of IPAs sequentially. A failed IPA doesn't abort the
    /// batch; failures are collected and reported in one aggregated error.
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

    /// Launches a guest under its configured runtime mode.
    func launch(_ app: InstalledApp) {
        let mode = GuestStore.runtimeMode(for: app.url)
        let outcome: LaunchOutcome
        switch mode {
        case .ios:
            outcome = RuntimeLauncher.launchiOS(installName: app.id)
        case .catalyst, .auto:
            outcome = RuntimeLauncher.launch(installName: app.id, mode: mode)
        }
        if outcome.ok {
            status = outcome.message
        } else {
            errorMessage = outcome.message
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

    /// String override from the guest's RunnerFeatures.plist ("" when unset).
    func spoofOverride(_ key: String, for app: InstalledApp) -> String {
        guard let plist = GuestStore.readRunnerFeatures(for: app.url),
              let value = plist[key] as? String else { return "" }
        return value
    }

    /// Writes a string override into the guest's RunnerFeatures.plist. An
    /// empty/whitespace value removes the key, so the hook falls back to its
    /// built-in default.
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

// MARK: - App entry point

@main
struct BaseiOSAppHostApp: App {
    @StateObject private var model = HostModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            HostCommands(model: model)
        }
    }
}

// MARK: - Menu-bar commands

/// Selection-aware menu commands. The "Guest" menu operates on the current
/// list selection; global actions live in File/View and the app menu.
struct HostCommands: Commands {
    @ObservedObject var model: HostModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import IPAs…") {
                model.pickAndImportIPAs()
            }
            .keyboardShortcut("o")
            .disabled(model.isWorking)
        }

        CommandGroup(after: .newItem) { Divider() }

        CommandGroup(after: .sidebar) {
            Button("Refresh") {
                model.reload()
            }
            .keyboardShortcut("r")
            .disabled(model.isWorking)
        }

        CommandMenu("Guest") {
            Button("Launch") {
                if let app = model.selection { model.launch(app) }
            }
            .keyboardShortcut("l")
            .disabled(model.selection == nil || model.isWorking)

            Divider()

            Button("Compatibility Settings…") {
                model.compatSheetApp = model.selection
            }
            .keyboardShortcut("i")
            .disabled(model.selection == nil)

            Button("Reset Keychain…") {
                model.keychainResetConfirmApp = model.selection
            }
            .disabled(model.selection == nil)

            Divider()

            Button("Delete App…", role: .destructive) {
                model.deleteConfirmApp = model.selection
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(model.selection == nil || model.isWorking)

            Divider()

            Button("Reset All Keychain Items…", role: .destructive) {
                model.confirmKeychainReset = true
            }
            .disabled(model.isWorking)
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject private var model: HostModel
    /// Local selection state: `List` writes its selection binding during the
    /// view-update pass, so binding it straight to the model's `@Published`
    /// property triggers "Publishing changes from within view updates".
    /// Mirror it into the model (which the Guest menu reads) via `onChange`.
    @State private var selection: InstalledApp?

    var body: some View {
        List(selection: $selection) {
            installedAppsSection
            statusSection
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("iOS App Loader")
        .toolbar { toolbarContent }
        .modifier(ContentViewSheets())
        .modifier(ContentViewAlerts())
        .onChange(of: selection) { _, newValue in
            model.selection = newValue
        }
        .onChange(of: model.apps) { _, apps in
            // Drop a stale selection if its app vanished (e.g. deleted via
            // the Guest menu while selected).
            if let sel = selection, !apps.contains(where: { $0.id == sel.id }) {
                selection = nil
            }
        }
        .task { model.reload() }
    }

    @ViewBuilder
    private var installedAppsSection: some View {
        Section("Installed apps") {
            if model.apps.isEmpty {
                Text("No apps installed yet.\nImport an IPA with ⌘O or the + button.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.apps) { app in
                    AppRow(app: app, model: model)
                        .tag(app)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.launch(app)
                        }
                        .contextMenu {
                            rowActions(app)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if model.isWorking || !model.status.isEmpty {
            Section("Status") {
                HStack {
                    if model.isWorking { ProgressView() }
                    Text(model.status).font(.callout)
                }
            }
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.pickAndImportIPAs()
            } label: {
                Label("Import IPAs", systemImage: "plus")
            }
            .help("Import IPAs (⌘O)")
            .disabled(model.isWorking)

            Button {
                model.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .disabled(model.isWorking)
        }
    }

    // Sheets and alerts live in ViewModifiers so the ContentView body
    // expression stays small enough for the type checker.
    private struct ContentViewSheets: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content
                // Import options sheet (staged by the open panel).
                .sheet(isPresented: Binding(
                    get: { model.pendingImportURLs != nil },
                    set: { if !$0 { model.pendingImportURLs = nil } }
                )) {
                    if let urls = model.pendingImportURLs {
                        ImportOptionsView(urls: urls)
                            .environmentObject(model)
                    }
                }
                // Compatibility settings sheet.
                .sheet(item: $model.compatSheetApp) { app in
                    CompatSettingsView(app: app)
                        .environmentObject(model)
                }
        }
    }

    private struct ContentViewAlerts: ViewModifier {
        func body(content: Content) -> some View {
            content
                .modifier(DeleteAppAlert())
                .modifier(ResetKeychainAlert())
                .modifier(ResetAllKeychainAlert())
                .modifier(ErrorAlert())
        }
    }

    private struct DeleteAppAlert: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content.alert(
                model.deleteConfirmApp.map { String(localized: "Delete \($0.displayName) and its data?") } ?? "",
                isPresented: Binding(
                    get: { model.deleteConfirmApp != nil },
                    set: { if !$0 { model.deleteConfirmApp = nil } }
                )
            ) {
                if let app = model.deleteConfirmApp {
                    Button("Delete", role: .destructive) {
                        model.deleteWithCleanup(app)
                        model.deleteConfirmApp = nil
                    }
                    Button("Cancel", role: .cancel) { model.deleteConfirmApp = nil }
                }
            } message: {
                Text("Removes the app bundle, the guest's data directory, and its keychain slot (wiped so the slot number can be reused).")
            }
        }
    }

    private struct ResetKeychainAlert: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content.alert(
                model.keychainResetConfirmApp.map { String(localized: "Reset keychain for \($0.displayName)?") } ?? "",
                isPresented: Binding(
                    get: { model.keychainResetConfirmApp != nil },
                    set: { if !$0 { model.keychainResetConfirmApp = nil } }
                )
            ) {
                if let app = model.keychainResetConfirmApp {
                    Button("Reset Keychain", role: .destructive) {
                        model.resetKeychain(for: app)
                        model.keychainResetConfirmApp = nil
                    }
                    Button("Cancel", role: .cancel) { model.keychainResetConfirmApp = nil }
                }
            } message: {
                Text("Deletes the app's keychain items (logins, sessions, tokens). The app stays installed and keeps its data.")
            }
        }
    }

    private struct ResetAllKeychainAlert: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content.alert(
                "Reset all keychain items?",
                isPresented: $model.confirmKeychainReset
            ) {
                Button("Reset All Keychain Items", role: .destructive) {
                    model.resetAllKeychainItems()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Every keychain item stored by guest apps will be deleted.")
            }
        }
    }

    private struct ErrorAlert: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content.alert(
                "Error",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ app: InstalledApp) -> some View {
        Button("Launch") { model.launch(app) }
        Button("Compatibility Settings…") { model.compatSheetApp = app }
        Button("Reset Keychain…") { model.keychainResetConfirmApp = app }
        Divider()
        Button("Delete…", role: .destructive) { model.deleteConfirmApp = app }
    }
}

// MARK: - Row

private struct AppRow: View {
    let app: InstalledApp
    @ObservedObject var model: HostModel

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.headline)
                if let bid = app.bundleIdentifier {
                    Text(bid)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            runtimeBadge
            if let version = app.version {
                Text(version)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var runtimeBadge: some View {
        let mode = model.runtimeModes[app.id] ?? .catalyst
        return Text(mode == .ios ? String(localized: "iOS") : mode == .auto ? String(localized: "Auto") : String(localized: "Catalyst"))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = model.icons[app.id] {
            Image(nsImage: icon)
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

// MARK: - Import sheet

/// Import confirmation / options sheet, shown after picking one or more IPAs.
/// Convert-time toggles are only offered for single imports — for a batch
/// they're troubleshooting knobs, and the batch runs with the defaults.
private struct ImportOptionsView: View {
    let urls: [URL]
    @EnvironmentObject private var model: HostModel
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(urls.count == 1 ? String(localized: "Selected app") : String(localized: "Selected apps (\(urls.count))")) {
                    ForEach(urls, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if urls.count == 1 {
                    Section {
                        ForEach(HostFeature.importOnly) { feature in
                            Toggle(isOn: Binding(
                                get: { enabled[feature.id] ?? (HostFeature.defaultValues[feature.id] ?? false) },
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
            }
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 240)

            HStack {
                Button("Cancel") {
                    model.pendingImportURLs = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import") {
                    let urls = self.urls
                    let features = enabled
                    Task {
                        await model.importIPAs(urls, importFeatures: features)
                    }
                    model.pendingImportURLs = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
            }
            .padding()
        }
    }
}

// MARK: - Compatibility sheet

/// Per-app settings sheet: runtime-mode + JIT selection and the runtime
/// hook toggles. Edits the guest's `RunnerFeatures.plist`; the runtime's
/// Loader consults it at launch to decide which host hooks run for this
/// specific guest.
private struct CompatSettingsView: View {
    let app: InstalledApp
    @EnvironmentObject private var model: HostModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Runtime", selection: Binding(
                        get: { model.runtimeMode(for: app) },
                        set: { model.setRuntimeMode($0, for: app) }
                    )) {
                        Text("Catalyst").tag(RuntimeMode.catalyst)
                        Text("iOS (Designed for iPad)").tag(RuntimeMode.ios)
                        Text("Auto").tag(RuntimeMode.auto)
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Runtime")
                } footer: {
                    Text("Data are shared between the runtimes.")
                }

                Section {
                    ForEach(HostFeature.all) { feature in
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
                } header: {
                    Text("Compatibility")
                } footer: {
                    Text("Runtime hooks can be used to mitigate issues with the guest app.")
                }

                if model.featureEnabled("deviceSpoof", for: app) {
                    DeviceSpoofFields(app: app)
                        .environmentObject(model)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 480)

            HStack {
                Button("Reset") {
                    for feature in HostFeature.all {
                        model.setFeature(feature.id, enabled: HostFeature.defaultValues[feature.id] ?? true, for: app)
                    }
                    for key in [DeviceSpoofConfig.machineKey,
                                DeviceSpoofConfig.modelKey,
                                DeviceSpoofConfig.osVersionKey] {
                        model.setSpoofOverride(key, value: "", for: app)
                    }
                }
                Spacer()
                Button("Done") {
                    model.compatSheetApp = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
}

/// Customizable device identity shown when the "Spoof device (sysctl)" hook
/// is enabled. Values are written to the guest's RunnerFeatures.plist and
/// read by DeviceSpoof.m at launch; empty fields use the built-in iPad
/// defaults.
private struct DeviceSpoofFields: View {
    let app: InstalledApp
    @EnvironmentObject private var model: HostModel

    /// Real (unspoofed) host identity, for the field hints.
    private let realMachine = GuestStore.realSysctlValue("hw.machine") ?? "unknown"
    private let realModel = GuestStore.realSysctlValue("hw.model") ?? "unknown"
    private let realOSVersion = GuestStore.realSysctlValue("kern.osproductversion") ?? "unknown"

    var body: some View {
        Section {
            spoofField("Machine (hw.machine)",
                       key: DeviceSpoofConfig.machineKey,
                       hint: String(localized: "Real: \(realMachine)"))
            spoofField("Model (hw.model)",
                       key: DeviceSpoofConfig.modelKey,
                       hint: String(localized: "Real: \(realModel); empty = same as machine"))
            spoofField("iOS version (kern.osproductversion)",
                       key: DeviceSpoofConfig.osVersionKey,
                       hint: String(localized: "Real: \(realOSVersion)"))
        } header: {
            Text("Device identity")
        } footer: {
            Text("Values returned by sysctl/sysctlbyname. Defaults to real device's values")
        }
    }

    private func spoofField(_ title: String, key: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(hint, text: Binding(
                get: { model.spoofOverride(key, for: app) },
                set: { model.setSpoofOverride(key, value: $0, for: app) }
            ))
            .textFieldStyle(.roundedBorder)
            Text(hint)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
