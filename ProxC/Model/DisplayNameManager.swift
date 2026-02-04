//
//  DisplayNameManager.swift
//  ProxC
//
//  Manages the user's display name for BLE chat.
//

import Foundation
import UIKit

class DisplayNameManager: ObservableObject {
    static let shared = DisplayNameManager()

    private let displayNameKey = "userDisplayName"
    static let maxLength = 15

    @Published var displayName: String {
        didSet {
            // Enforce max length
            if displayName.count > DisplayNameManager.maxLength {
                displayName = String(displayName.prefix(DisplayNameManager.maxLength))
            }
            UserDefaults.standard.set(displayName, forKey: displayNameKey)
        }
    }

    private init() {
        // Load saved display name or default to device name
        if let savedName = UserDefaults.standard.string(forKey: displayNameKey), !savedName.isEmpty {
            self.displayName = String(savedName.prefix(DisplayNameManager.maxLength))
        } else {
            // Default to device name (truncated to max length)
            let deviceName = UIDevice.current.name
            self.displayName = String(deviceName.prefix(DisplayNameManager.maxLength))
        }
    }

    /// Returns the display name to use for BLE communication
    var nameForBLE: String {
        return displayName.isEmpty ? "ProxC User" : displayName
    }

    /// Resets the display name to the device name
    func resetToDeviceName() {
        let deviceName = UIDevice.current.name
        displayName = String(deviceName.prefix(DisplayNameManager.maxLength))
    }
}
