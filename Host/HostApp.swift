//
//  HostApp.swift
//  BaseiOSAppHost
//

import SwiftUI

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

            Divider()

            Menu("Open Runtime Home in Finder") {
                Button("Catalyst Runtime") {
                    model.revealRuntimeHome(.catalyst)
                }

                Button("iOS Runtime") {
                    model.revealRuntimeHome(.ios)
                }
            }
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
