//
//  ContentView.swift
//  BaseiOSAppHost
//

import SwiftUI

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject private var model: HostModel
    /// Mirrored into the model via onChange (a direct binding to @Published
    /// triggers "Publishing changes from within view updates").
    @State private var selection: InstalledApp?
    /// Auto-dismisses the floating status toast once work has finished.
    @State private var toastDismissTask: Task<Void, Never>?
    /// True while an IPA drag hovers the window.
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            List(selection: $selection) {
                installedAppsSection
            }
            // No zebra stripes: filler stripes use the default row height
            // and clash with the taller icon rows.
            .listStyle(.inset)
            // Native double-click / Return launch; per-row tap gestures
            // fought with list selection.
            .contextMenu(forSelectionType: InstalledApp.self) { apps in
                if let app = apps.first { rowActions(app) }
            } primaryAction: { apps in
                if let app = apps.first { model.launch(app) }
            }
            .overlay { emptyState }
            .dropDestination(for: URL.self) { urls, _ in
                let ipas = urls.filter { $0.pathExtension.lowercased() == "ipa" }
                guard !model.isWorking else { return false }
                guard !ipas.isEmpty else {
                    model.postInfo(String(localized: "Only .ipa files can be imported"))
                    return false
                }
                Task { await model.importIPAs(ipas) }
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .top) { signingBanner }

            StatusToast()
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("iOS App Loader")
        .toolbar { toolbarContent }
        .modifier(ContentViewSheets())
        .modifier(ContentViewAlerts())
        .onChange(of: selection) { _, newValue in
            model.selection = newValue
        }
        .onChange(of: model.apps) { _, apps in
            // Drop a stale selection if its app vanished.
            if let sel = selection, !apps.contains(where: { $0.id == sel.id }) {
                selection = nil
            }
        }
        .onChange(of: model.status) { _, _ in scheduleToastDismissal() }
        .animation(.snappy(duration: 0.25), value: model.isWorking)
        .onChange(of: model.isWorking) { _, _ in
            // Reschedule on working-state flips without a status change.
            scheduleToastDismissal()
        }
        .task { model.reload() }
    }

    /// Hides the toast a few seconds after activity settles; while work is
    /// in flight it stays pinned to the progress.
    private func scheduleToastDismissal() {
        toastDismissTask?.cancel()
        guard !model.isWorking else { return }
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.25)) { model.status = "" }
        }
    }

    /// Free Apple ID profiles lapse weekly; warn while a rebuild is still
    /// possible from inside the app's working window.
    @ViewBuilder
    private var signingBanner: some View {
        if let expiry = model.signingExpiry, expiry.timeIntervalSinceNow < 2 * 24 * 60 * 60 {
            let relative = expiry.formatted(.relative(presentation: .named))
            let expired = expiry < .now
            Label(expired
                  ? String(localized: "Signing expired \(relative). Rebuild the app with the same Apple ID to keep launching apps.")
                  : String(localized: "Signing expires \(relative). Rebuild the app with the same Apple ID."),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background((expired ? Color.red : Color.yellow).opacity(0.2))
        }
    }

    @ViewBuilder
    private var installedAppsSection: some View {
        ForEach(model.apps) { app in
            AppRow(app: app, model: model)
                .tag(app)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.apps.isEmpty {
            ContentUnavailableView {
                Label("No Apps", systemImage: "square.and.arrow.down")
            } description: {
                Text("Drop IPA files here, or import them with ⌘O.")
            } actions: {
                Button("Import IPAs…") { model.pickAndImportIPAs() }
                    .disabled(model.isWorking)
            }
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let app = selection { model.launch(app) }
            } label: {
                Label("Launch", systemImage: "play.fill")
            }
            .help("Launch the selected app (⌘L or Return)")
            .disabled(selection == nil || model.isWorking)

            Button {
                model.pickAndImportIPAs()
            } label: {
                Label("Import IPAs", systemImage: "plus")
            }
            .help("Import IPAs (⌘O), or drop them onto the window")
            .disabled(model.isWorking)
        }
    }

    // Sheets and alerts live in ViewModifiers so the ContentView body
    // expression stays small enough for the type checker.
    private struct ContentViewSheets: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content
                // Committing the runtime selection (migrating the guest into
                // the selected flavor's container) happens in onDisappear,
                // which fires on every dismissal path.
                .sheet(item: $model.compatSheetApp) { app in
                    CompatSettingsView(app: app)
                        .environmentObject(model)
                        .onDisappear { model.applyRuntimeSelection(for: app) }
                }
        }
    }

    private struct ContentViewAlerts: ViewModifier {
        func body(content: Content) -> some View {
            content
                .modifier(DeleteAppAlert())
                .modifier(ResetKeychainAlert())
                .modifier(ResetAllKeychainAlert())
                .modifier(KillRuntimesAlert())
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

    private struct KillRuntimesAlert: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content.alert(
                "Kill all runtimes?",
                isPresented: $model.confirmKillRuntimes
            ) {
                Button("Kill All", role: .destructive) {
                    model.killRuntimes()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Every running app is force-quit immediately. Unsaved progress is lost.")
            }
        }
    }

    private struct ErrorAlert: ViewModifier {
        @EnvironmentObject private var model: HostModel

        func body(content: Content) -> some View {
            content.alert(
                model.errorTitle ?? String(localized: "Something Went Wrong"),
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil; model.errorTitle = nil } }
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
        Group {
            Button("Launch") { model.launch(app) }
            Button("Compatibility Settings…") { model.compatSheetApp = app }
            Button("Reset Keychain…") { model.keychainResetConfirmApp = app }
            Divider()
            Button("Delete…", role: .destructive) { model.deleteConfirmApp = app }
        }
        .disabled(model.isWorking)
    }
}
