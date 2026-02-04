//
//  ProxCApp.swift
//  ProxC
//
//  Created by Manuel Hidalgo Sola on 9/4/24.
//

import SwiftUI

// ProxCApp.swift
@main
struct ProxCApp: App {
    @StateObject private var bluetoothManager = BluetoothManager()
    var body: some Scene {
        WindowGroup {
            ContactsView()
                .environmentObject(bluetoothManager)
        }
    }
}

