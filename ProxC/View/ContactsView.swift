//
//  ContactsView.swift
//  ProxC
// free young thug
//  Created by Manuel Hidalgo Sola on 9/4/24.
//

import SwiftUI
import CoreBluetooth

class ContactsViewModel: ObservableObject {
    // Published properties to manage state in ContactsView
    @Published var showingChat: Bool = false          // To control when to show ChatView
    @Published var showConnectionResult: Bool = false // To control when to show connection status alert
    @Published var showTerminationAlert: Bool = false // To control when to show chat ended notification
    @Published var terminationMessage: String = ""    // Message to show in termination alert
    
    // Track when chat was opened to prevent immediate termination
    var chatOpenedAt: Date?

    // Example of a method to handle connection logic
    func updateConnectionStatusMessage(status: String) {
        if status.contains("Accepted") {
            showingChat = true
            chatOpenedAt = Date()
        }
    }
}

struct ContactsView: View {
    @StateObject var viewModel = ContactsViewModel()
    @EnvironmentObject var bluetoothManager: BluetoothManager
    @State private var selectedContact: CBPeripheral?
    
    
    var body: some View {
        NavigationView {
            VStack {
                if bluetoothManager.isBluetoothPoweredOn {
                    if bluetoothManager.discoveredDevices.isEmpty {
                        Text("No nearby devices found")
                            .foregroundColor(.gray)
                            .font(.title2)
                            .padding()
                    } else {
                        List {
                            ForEach(bluetoothManager.discoveredDevices, id: \.identifier) { peripheral in
                                Button(action: {
                                    selectedContact = peripheral
                                    bluetoothManager.connectToPeripheral(peripheral)
                                }) {
                                    HStack {
                                        Text(peripheral.name ?? "Unknown Device")
                                            .foregroundColor(.black)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                        .listStyle(PlainListStyle())
                    }
                } else {
                    Text("Turn on Bluetooth to connect")
                        .foregroundColor(.red)
                        .font(.title2)
                        .padding()
                }
            }
            .navigationTitle("Nearby Devices")
            .navigationBarItems(trailing: Button(action: {
                bluetoothManager.stopScan()
                bluetoothManager.startScan()
            }) {
                Image(systemName: "arrow.clockwise")
            })
            .alert(isPresented: $bluetoothManager.showAlert) {
                Alert(
                    title: Text("Connection Request"),
                    message: Text("Do you want to accept the connection request?"),
                    primaryButton: .default(Text("Accept")) {
                        bluetoothManager.acceptConnectionRequest()
                        print("Accept tapped; sending Accepted response")
                    },
                    secondaryButton: .cancel(Text("Reject")) {
                        bluetoothManager.rejectConnectionRequest()
                        print("Reject tapped; sending Rejected response")
                    }
                )
            }
            .sheet(isPresented: $viewModel.showingChat) {
                if let connectedCentral = bluetoothManager.connectedCentral  {
                    ChatView(central: connectedCentral, onEndChatConfirmed: {
                        bluetoothManager.terminateSessionInitiatedByUser()
                    }, bluetoothManager: bluetoothManager)
                } else if let connectedPeripheral = bluetoothManager.connectedPeripheral {
                    ChatView(contact: connectedPeripheral, onEndChatConfirmed: {
                        bluetoothManager.terminateSessionInitiatedByUser()
                    }, bluetoothManager: bluetoothManager)
                }
            }
            .onChange(of: viewModel.showingChat) { showing in
                if showing {
                    // Chat is opening, record the time
                    viewModel.chatOpenedAt = Date()
                } else {
                    // Chat closed - no automatic termination, user must confirm via End Chat button
                    viewModel.chatOpenedAt = nil
                }
            }
            .onChange(of: bluetoothManager.connectionStatusMessage) { status in
                if status == "Accepted" || status.contains("Accepted connection") {
                    print("ContactsView: Detected Accepted status, opening chat")
                    viewModel.showingChat = true
                    viewModel.chatOpenedAt = Date()
                }
                // Note: Termination is now handled via bluetoothManager.remoteChatEnded
            }
            .onChange(of: bluetoothManager.responseStatusMessage){
                status in if status.contains("Accepted"){
                    viewModel.showingChat = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatShouldPresent)) { _ in
                viewModel.showingChat = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatShouldDismiss)) { _ in
                viewModel.showingChat = false
            }
            .onChange(of: bluetoothManager.remoteChatEnded) { ended in
                if ended {
                    viewModel.terminationMessage = "The other device ended the chat."
                    viewModel.showTerminationAlert = true
                    bluetoothManager.acknowledgeRemoteChatEnded()
                }
            }
            .alert("Chat Ended", isPresented: $viewModel.showTerminationAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.terminationMessage)
            }
        }
    }
}




#Preview {
    ContactsView()
        .environmentObject(BluetoothManager())
}

