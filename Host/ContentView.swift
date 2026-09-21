//
//  ContentView.swift
//  BaseiOSAppHost
//

import SwiftUI

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject private var model: HostModel
    /// Local selection state: `List` writes its selection binding during the
    /// view-update pass, so binding it straight to the model's `@Published`
    /// property triggers "Publishing changes from within view updates".
    /// Mirror it into the model (which the Guest menu reads) via `onChange`.
    @State private var selection: InstalledApp?
    /// Auto-dismisses the floating status toast once work has finished.
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            List(selection: $selection) {
                installedAppsSection
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

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
            // Drop a stale selection if its app vanished (e.g. deleted via
            // the Guest menu while selected).
            if let sel = selection, !apps.contains(where: { $0.id == sel.id }) {
                selection = nil
            }
        }
        .onChange(of: model.status) { _, _ in scheduleToastDismissal() }
        .animation(.snappy(duration: 0.25), value: model.isWorking)
        .onChange(of: model.isWorking) { _, _ in
            // Working state flips without a status change (e.g. delete/launch
            // results); reschedule the dismissal so the toast lingers briefly.
            scheduleToastDismissal()
        }
        .task { model.reload() }
    }

    /// Hides the toast a few seconds after the latest activity settles.
    /// While work is in flight the toast stays pinned to the progress.
    private func scheduleToastDismissal() {
        toastDismissTask?.cancel()
        guard !model.isWorking else { return }
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.25)) { model.status = "" }
        }
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
                // Compatibility settings sheet. Closing it (Done, Esc, or
                // clicking outside) commits the runtime selection: the
                // guest is migrated into the selected flavor's container
                // right here, never at launch.
                .sheet(isPresented: Binding(
                    get: { model.compatSheetApp != nil },
                    set: { newValue in
                        if !newValue, let app = model.compatSheetApp {
                            model.applyRuntimeSelection(for: app)
                        }
                        model.compatSheetApp = nil
                    }
                )) {
                    if let app = model.compatSheetApp {
                        CompatSettingsView(app: app)
                            .environmentObject(model)
                    }
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
