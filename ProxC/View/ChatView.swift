//
//  ChatView.swift
//  ProxC
//
//  Created by Manuel Hidalgo Sola on 9/4/24.
//

import SwiftUI
import CoreBluetooth // Import CoreBluetooth to recognize Bluetooth-related types like CBPeripheral

struct ChatView: View {
    //@State private var messages: [Message] = []
    @State private var currentMessage: String = ""
    var contact: CBPeripheral? // The Bluetooth contact you are connected with
    var central: CBCentral?
    
    @ObservedObject var bluetoothManager: BluetoothManager
     
    
   // func addMessage(_ message: Message) {
   //         messages.append(message)  // Method to add a new message
   //     }
    
    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(bluetoothManager.messages) { message in
                        MessageBubble(message: message)
                    }
                }
            }
            
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
        .navigationTitle(chatTitle())
        .navigationBarTitleDisplayMode(.inline)
    }
    
    func chatTitle() -> String {
        if let contact = contact {
            return "Chat with \(contact.name ?? "Unknown Device")"  // If connected to peripheral
        } else if let central = central {
            return "Chat with Central: \(central.identifier.uuidString)"  // If connected to central
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

