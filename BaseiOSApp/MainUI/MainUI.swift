//
//  MainUI.swift
//  BaseiOSApp
//
//  Created by Venti on 25/2/26.
//


import Foundation
import SwiftUI

@objc public class MainUI: NSObject {
    @objc public func createAlertWithTitle(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        if let rootVC = UIApplication.shared.windows.first?.rootViewController {
            rootVC.present(alert, animated: true, completion: nil)
        }
    }
}
