//
//  HostModel+Settings.swift
//  BaseiOSAppHost
//

import Foundation

extension HostModel {

    // MARK: - Keychain

    /// Per-app keychain reset: deletes the guest's keychain items but keeps
    /// its slot assignment.
    func resetKeychain(for app: InstalledApp) {
        guard !isWorking else { return }
        guard let bid = app.bundleIdentifier, !bid.isEmpty else {
            fail(String(localized: "Couldn't Reset Keychain"),
                 String(localized: "\(app.displayName) has no bundle ID, so there is nothing to reset."))
            return
        }
        isWorking = true
        status = String(localized: "Resetting \(app.displayName) keychain…")
        Task {
            do {
                let slot = try await Task.detached(priority: .userInitiated) {
                    try KeychainManager.resetKeychain(bundleID: bid)
                }.value
                status = String(localized: "Reset keychain (slot \(slot))")
            } catch {
                fail(String(localized: "Couldn't Reset Keychain"), error.localizedDescription)
            }
            isWorking = false
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
        guard let located = GuestStore.locateInstalledGuest(installName: installName) else {
            errorMessage = String(localized: "Could not find \(installName) in either runtime container.")
            return
        }
        let target: RuntimeFlavor = GuestStore.runtimeMode(for: located.url) == .ios ? .ios : .catalyst
        // Closing the sheet without switching runtimes is not a migration.
        guard located.flavor != target else { return }
        isWorking = true
        status = String(localized: "Moving \(app.displayName) between runtime containers…")
        Task.detached(priority: .userInitiated) { [weak self] in
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
                    self?.fail(String(localized: "Couldn't Switch Runtime"), error.localizedDescription)
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        GuestStore.writeRunnerFeatures(trimmed.isEmpty ? [:] : [key: trimmed],
                                       remove: trimmed.isEmpty ? [key] : [],
                                       defaults: HostFeature.defaultValues, for: app.url)
        objectWillChange.send()
    }
}
