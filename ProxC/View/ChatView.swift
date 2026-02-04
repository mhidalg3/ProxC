//
//  ChatView.swift
//  ProxC
//
//  Created by Manuel Hidalgo Sola on 9/4/24.
//

import SwiftUI
import CoreBluetooth // Import CoreBluetooth to recognize Bluetooth-related types like CBPeripheral

struct ChatView: View {
    @State private var currentMessage: String = ""
    @State private var showEndChatConfirmation: Bool = false

    var contact: CBPeripheral? // The Bluetooth contact you are connected with
    var central: CBCentral?
    var onEndChatConfirmed: (() -> Void)?  // Callback when user confirms ending chat

    @ObservedObject var bluetoothManager: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Custom header - works consistently across iOS versions
            HStack {
                Text(chatTitle())
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button(action: {
                    showEndChatConfirmation = true
                }) {
                    Text("End Chat")
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))

            Divider()

            // Messages
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(bluetoothManager.messages) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding(.top, 8)
            }

            // Message input
            HStack {
                TextField("Type a message...", text: $currentMessage)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(minHeight: 30)

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                }
            }
            .padding()
        }
        .background(Color(UIColor.systemBackground))
        .alert("End Chat?", isPresented: $showEndChatConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                onEndChatConfirmed?()
                dismiss()
            }
        } message: {
            Text("Are you sure you want to end this chat?")
        }
        .interactiveDismissDisabled(true)  // Prevent swipe-to-dismiss
    }
    
    func chatTitle() -> String {
        // Use connectedDeviceName if available (set from connection request payload)
        if let deviceName = bluetoothManager.connectedDeviceName, !deviceName.isEmpty {
            return "Chat with \(deviceName)"
        } else if let contact = contact {
            return "Chat with \(contact.name ?? "Unknown Device")"  // If connected to peripheral
        } else if let central = central {
            return "Chat with \(central.identifier.uuidString.prefix(8))..."  // If connected to central (shortened UUID)
        } else {
            return "Chat"  // Fallback in case neither is set
        }
    }
    
    // Function to send a message over Bluetooth
    //func sendMessage() {
    //    guard !currentMessage.isEmpty else { return }
    //    // Code to send the message over Bluetooth to the connected contact
    //    let newMessage = Message(text: currentMessage, isSentByUser: true)
    //    messages.append(newMessage)
    //    currentMessage = ""
    //}
    func sendMessage() {
        guard !currentMessage.isEmpty else { return }
        if let contact = contact {
            bluetoothManager.sendMessageToPeripheral(contact, message: currentMessage)
        } else if let central = central {
            bluetoothManager.sendMessageToCentral(central, message: currentMessage)
        }
        currentMessage = ""
    }



    
}

