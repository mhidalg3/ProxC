//
//  DisplayNameSettingsView.swift
//  ProxC
//
//  View for setting the user's display name.
//

import SwiftUI

struct DisplayNameSettingsView: View {
    @ObservedObject var displayNameManager = DisplayNameManager.shared
    @EnvironmentObject var bluetoothManager: BluetoothManager
    @Environment(\.dismiss) private var dismiss
    @State private var editingName: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Display Name")) {
                    TextField("Enter display name", text: $editingName)
                        .onChange(of: editingName) { newValue in
                            // Enforce max length while typing
                            if newValue.count > DisplayNameManager.maxLength {
                                editingName = String(newValue.prefix(DisplayNameManager.maxLength))
                            }
                        }
                    Text("\(editingName.count)/\(DisplayNameManager.maxLength) characters")
                        .font(.caption)
                        .foregroundColor(editingName.count >= DisplayNameManager.maxLength ? .red : .gray)
                }

                Section(footer: Text("This name will be shown to other devices when you connect.")) {
                    Button("Reset to Device Name") {
                        displayNameManager.resetToDeviceName()
                        editingName = displayNameManager.displayName
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        displayNameManager.displayName = editingName
                        // Restart advertising to pick up the new display name
                        bluetoothManager.restartAdvertisingForNameChange()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                editingName = displayNameManager.displayName
            }
        }
    }
}

#Preview {
    DisplayNameSettingsView()
        .environmentObject(BluetoothManager())
}
