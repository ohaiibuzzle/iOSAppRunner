//
//  GuestSceneDelegate.swift
//  BaseiOSApp
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

        // Adopt a guest window created before the scene connected (lifecycle
        // race); fall back to a blank placeholder otherwise.
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
