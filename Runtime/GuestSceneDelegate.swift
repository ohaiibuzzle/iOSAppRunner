//
//  GuestSceneDelegate.swift
//  BaseiOSApp
//
//  Scene delegate installed on guest bundles via the `UIApplicationSceneManifest`
//  injected at import time by the host's GuestStore. Catalyst requires the scene
//  lifecycle, so when a (typically non-scene) iOS guest calls `UIApplicationMain`
//  it must still wind up inside a real `UIWindowScene`.
//
//  The guest's own app delegate creates its window the legacy way (an orphan
//  `UIWindow` with no scene). Our `makeKeyAndVisible` interposition
//  (`WindowHooks.m`) attaches that window to *this* scene, so whatever the guest
//  added — root view controller or bare subviews — renders. This delegate just
//  registers the scene and removes its own placeholder once a guest window shows.
//

import UIKit

@_silgen_name("SetGuestWindowScene")
func c_SetGuestWindowScene(_ scene: UnsafeRawPointer)

@_silgen_name("SetGuestPlaceholderWindow")
func c_SetGuestPlaceholderWindow(_ window: UnsafeRawPointer)

@_silgen_name("GuestAdoptSceneLessWindows")
func c_GuestAdoptSceneLessWindows() -> UnsafeRawPointer?

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
    }
}
