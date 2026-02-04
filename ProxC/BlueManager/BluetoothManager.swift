//
//  BluetoothManager.swift
//  ProxC
//
//  Created by Manuel Hidalgo Sola on 9/4/24.
//


import Foundation
import CoreBluetooth
import SwiftUI
import UserNotifications
import UIKit

extension Notification.Name {
    static let chatDidDismiss = Notification.Name("ChatDidDismiss")
    static let chatShouldDismiss = Notification.Name("ChatShouldDismiss")
    static let chatShouldPresent = Notification.Name("ChatShouldPresent")
}

// Define the service and characteristic UUIDs
struct BluetoothConstants {
    static let serviceUUID = CBUUID(string: "E4E656C1-B5DF-4A2D-AB98-7E5E88C0869C")
    static let connectionRequestCharacteristicUUID = CBUUID(string: "E4E656C2-B5DF-4A2D-AB98-7E5E88C0869C")
    static let connectionResponseCharacteristicUUID = CBUUID(string: "E4E656C3-B5DF-4A2D-AB98-7E5E88C0869C")
    static let connectionChatCharacteristicUUID = CBUUID(string: "E4E656C4-B5DF-4A2D-AB98-7E5E88C0869C")
}

@MainActor
class BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var isBluetoothPoweredOn = false
    @Published var connectedPeripheral: CBPeripheral?
    @Published var connectedCentral: CBCentral?
    @Published var showAlert = false
    @Published var connectionCentral: CBCentral?
    @Published var connectionStatusMessage: String = ""
    @Published var responseStatusMessage: String = ""
    @Published var messages: [Message] = []
    @Published var ison = 0
    @Published var remoteChatEnded = false  // Set when remote device terminates chat
    @Published var connectedDeviceName: String?  // Name of the connected device (for display)
    @Published var peripheralAdvertisedNames: [UUID: String] = [:]  // Stores advertised names for discovered peripherals
    //var viewModel: ContactsViewModel
    //var chatModel: ChatView
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    //private var bluetoothManager: BluetoothManager
    private var requestWriteCharacteristic: CBCharacteristic?                 // Central-side: write to request
    private var chatCharacteristicOnCentral: CBCharacteristic?                // Central-side: write to chat + receive notify
    private var requestWriteCharacteristicPeripheral: CBMutableCharacteristic? // Peripheral-side: receives request writes
    private var responseNotifyCharacteristicPeripheral: CBMutableCharacteristic? // Peripheral-side: notifies accept/deny
    private var chatCharacteristicOnPeripheral: CBMutableCharacteristic?      // Peripheral-side: notifies chat + receives writes
    
    private var responseNotifyCharacteristicOnCentral: CBCharacteristic?
    private var awaitingConnectionResponse = false
    private var pendingResponsePacket: Data?
    
    private var servicesAdded = false
    private var processedKeys = Set<MessageKey>()
    private var seenAckIds = Set<UInt64>()
    private var didSendConnectionRequest = false
    private var responseNotifyEnabled = false
    private var serviceDiscoveryRetries: [UUID: Int] = [:]
    private var userInitiatedDisconnect = false  // Track if WE initiated the disconnect

    // Deleted these lines per instructions:
    // private var conversationId = UUID()
    // private var nextMessageId: UInt64 = 1

    // Protocol/reliability state
    private var currentConversationId: UUID = UUID()
    private var nextMessageId: UInt64 = 1
    private var reassemblyBuffer = ReassemblyBuffer()
    private let ackTimeout: TimeInterval = 5.0
    private let maxRetries: Int = 3

    private final class PendingSend {
        var fragments: [Data]
        var retryCount: Int
        var timer: Timer?
        init(fragments: [Data], retryCount: Int = 0, timer: Timer? = nil) {
            self.fragments = fragments
            self.retryCount = retryCount
            self.timer = timer
        }
    }

    private var pendingToPeripheral: [UInt64: PendingSend] = [:]
    private var pendingToCentral: [UInt64: PendingSend] = [:]

    // MARK: - Initialization
    override init() {
        super.init()
        // Gate state restoration on presence of background modes to avoid runtime exception on device
        let bgModes = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
        let hasCentralBG = bgModes.contains("bluetooth-central")
        let hasPeripheralBG = bgModes.contains("bluetooth-peripheral")
        let centralOptions: [String: Any]? = hasCentralBG ? [CBCentralManagerOptionRestoreIdentifierKey: "com.proxc.central"] : nil
        let peripheralOptions: [String: Any]? = hasPeripheralBG ? [CBPeripheralManagerOptionRestoreIdentifierKey: "com.proxc.peripheral"] : nil

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: centralOptions
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: peripheralOptions
        )
        requestNotificationAuthorization()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleChatDidDismissNotification(_:)),
                                               name: .chatDidDismiss,
                                               object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .chatDidDismiss, object: nil)
    }
    
    private func resetServiceDiscoveryRetries(for peripheral: CBPeripheral) {
        serviceDiscoveryRetries[peripheral.identifier] = 0
    }

    private func retryServiceDiscovery(for peripheral: CBPeripheral, delay: TimeInterval = 0.5, maxAttempts: Int = 10) {
        let attempts = (serviceDiscoveryRetries[peripheral.identifier] ?? 0) + 1
        guard attempts <= maxAttempts else {
            print("Service discovery max attempts reached for \(peripheral.identifier)")
            return
        }
        serviceDiscoveryRetries[peripheral.identifier] = attempts
        print("Retrying service discovery attempt #\(attempts) for \(peripheral.identifier) in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral else { return }
            peripheral.discoverServices([BluetoothConstants.serviceUUID])
        }
    }
    
    // MARK: - Central Role: Scanning and Connecting
    //var onMessageReceived: ((String) -> Void)?
    func startScan() {
        guard centralManager.state == .poweredOn else {
            print("Central Manager is not powered on.")
            return
        }
        print("Starting scan for peripherals with service UUID: \(BluetoothConstants.serviceUUID.uuidString)")
        centralManager.scanForPeripherals(withServices: [BluetoothConstants.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    func stopScan() {
        centralManager.stopScan()
        print("Stopped scanning for peripherals.")
    }
    // no working new func
    func userDidSelectPeripheral(at index: Int) {
        let selectedPeripheral = discoveredDevices[index]
        
        // Store the selected peripheral and its characteristic
        selectedPeripheral.delegate = self
        //connectedPeripheral = selectedPeripheral
        
        // Discover services on the selected peripheral to find the characteristic to write to
        selectedPeripheral.discoverServices([CBUUID(string: "YOUR-SERVICE-UUID")])
    }

    
    //func sendConnectionRequest(to peripheral: CBPeripheral) {
    //        print("Connecting to peripheral: \(peripheral.name ?? "Unknown Device")")
    //        centralManager.connect(peripheral, options: nil)
    //}
    func connectToPeripheral(_ peripheral: CBPeripheral) {
        print("Attempting to connect to \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
        // stop scan
        centralManager.stopScan()
        // Initiate connection to the peripheral
        centralManager.connect(peripheral, options: nil)
    }
    func sendConnectionRequest(to peripheral: CBPeripheral) {
        print("attempting transition")
        // Generate a new conversation ID for this session
        currentConversationId = UUID()
        // Include display name in payload so peripheral can display it
        let displayName = DisplayNameManager.shared.nameForBLE
        let payload = displayName.data(using: .utf8) ?? Data()
        let packet = Packet(type: .connectionRequest,
                            conversationId: currentConversationId,
                            messageId: 0,
                            fragmentIndex: 0,
                            fragmentCount: 1,
                            payload: payload)
        if let characteristic = requestWriteCharacteristic {
            let data = packet.encode()
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            print("Connection request (packet) sent to peripheral with conversationId: \(currentConversationId), displayName: \(displayName)")
        } else {
            print("Request write characteristic not set")
        }
    }

    
    // MARK: - Peripheral Role: Advertising
    func startAdvertising() {
        print("Setting up GATT service and characteristics")
        guard peripheralManager.state == .poweredOn else {
            print("Peripheral Manager is not powered on.")
            return
        }

        // If service is already set up, just restart advertising without recreating characteristics
        if servicesAdded && requestWriteCharacteristicPeripheral != nil {
            print("Service already added; restarting advertising only")
            peripheralManager.startAdvertising([
                CBAdvertisementDataLocalNameKey: DisplayNameManager.shared.nameForBLE,
                CBAdvertisementDataServiceUUIDsKey: [BluetoothConstants.serviceUUID]
            ])
            return
        }

        // Define the connection request characteristic
        requestWriteCharacteristicPeripheral = CBMutableCharacteristic(
            type: BluetoothConstants.connectionRequestCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )

        // Define the connection response characteristic
        responseNotifyCharacteristicPeripheral = CBMutableCharacteristic(
            type: BluetoothConstants.connectionResponseCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        chatCharacteristicOnPeripheral = CBMutableCharacteristic(
            type: BluetoothConstants.connectionChatCharacteristicUUID,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable, .readable]
        )

        // Create the service and add characteristics
        let service = CBMutableService(type: BluetoothConstants.serviceUUID, primary: true)
        service.characteristics = [requestWriteCharacteristicPeripheral!, responseNotifyCharacteristicPeripheral!, chatCharacteristicOnPeripheral!]
        peripheralManager.add(service)
        print("Service added to peripheral manager; advertising will start in didAdd")
    }
    
    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        print("Stopped advertising.")
    }
    
    // MARK: - Handling Responses
    func sendResponse(_ response: String, to central: CBCentral) {
        guard let characteristic = responseNotifyCharacteristicPeripheral else {
            print("Connection Response Characteristic not found.")
            return
        }
        
        if let data = response.data(using: .utf8) {
            peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: [central])
            print("Sent response: \(response) to central: \(central.identifier.uuidString)")
        }
    }


    // MARK: - Termination
    func terminateSessionInitiatedByUser() {
        print("terminateSessionInitiatedByUser called")
        // Prefer central role (we can actively cancel)
        if let peripheral = connectedPeripheral {
            // Send terminate packet over chat characteristic (central writes)
            if let chatChar = chatCharacteristicOnCentral {
                let pkt = Packet(type: .connectionTerminate,
                                 conversationId: currentConversationId,
                                 messageId: 0,
                                 fragmentIndex: 0,
                                 fragmentCount: 1,
                                 payload: Data())
                let data = pkt.encode()
                peripheral.writeValue(data, for: chatChar, type: .withResponse)
                print("Sent connectionTerminate packet to peripheral")
            }
            // Mark that WE initiated this disconnect so we don't show "Chat ended" to ourselves
            userInitiatedDisconnect = true
            // Cancel the BLE connection
            centralManager.cancelPeripheralConnection(peripheral)
            connectedPeripheral = nil
            connectionStatusMessage = "Terminated"
            cleanupSession()
        } else if let central = connectedCentral {
            // Mark that WE initiated this termination so we don't show "Chat ended" to ourselves
            userInitiatedDisconnect = true
            // Send terminate packet over chat characteristic (peripheral notifies)
            if let chatChar = chatCharacteristicOnPeripheral {
                let pkt = Packet(type: .connectionTerminate,
                                 conversationId: currentConversationId,
                                 messageId: 0,
                                 fragmentIndex: 0,
                                 fragmentCount: 1,
                                 payload: Data())
                let data = pkt.encode()
                _ = peripheralManager.updateValue(data, for: chatChar, onSubscribedCentrals: [central])
                print("Notified connectionTerminate packet to central")
            }
            connectedCentral = nil
            connectionStatusMessage = "Terminated"
            cleanupSession()
        } else {
            print("No active session to terminate")
        }
    }

    private func cleanupSession() {
        print("Cleaning up session state")
        // Clear reliability state and caches
        pendingToPeripheral.values.forEach { $0.timer?.invalidate() }
        pendingToCentral.values.forEach { $0.timer?.invalidate() }
        pendingToPeripheral.removeAll()
        pendingToCentral.removeAll()
        reassemblyBuffer.removeAll()
        processedKeys.removeAll()
        seenAckIds.removeAll()
        didSendConnectionRequest = false
        responseNotifyEnabled = false
        // Reset status messages so onChange can fire on next connection
        connectionStatusMessage = ""
        responseStatusMessage = ""
        // Clear connected device name
        connectedDeviceName = nil
        // Clear messages per ephemeral chat requirement
        messages.removeAll()
        // Note: remoteChatEnded and userInitiatedDisconnect are intentionally NOT reset here
        // - remoteChatEnded: UI needs to see it first
        // - userInitiatedDisconnect: used by didDisconnectPeripheral callback
    }

    // MARK: - Notifications
    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification auth error: \(error.localizedDescription)")
            } else {
                print("Notification authorization: \(granted)")
            }
        }
    }

    private func scheduleIncomingRequestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Connection Request"
        content.body = "A nearby device wants to chat."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Protocol helpers
    private func sendFragmentsToPeripheral(_ peripheral: CBPeripheral, fragments: [Data]) {
        print("Sending \(fragments.count) fragment(s) to peripheral \(peripheral.identifier)")
        guard let chatChar = chatCharacteristicOnCentral else {
            print("Chat characteristic (central) not found for sending")
            return
        }
        for fragment in fragments {
            peripheral.writeValue(fragment, for: chatChar, type: .withResponse)
        }
    }

    private func sendFragmentsToCentral(_ central: CBCentral, fragments: [Data]) {
        print("Sending \(fragments.count) fragment(s) to central \(central.identifier)")
        guard let chatChar = chatCharacteristicOnPeripheral else {
            print("Peripheral chat characteristic (peripheral) not found for notifying")
            return
        }
        for fragment in fragments {
            let ok = peripheralManager.updateValue(fragment, for: chatChar, onSubscribedCentrals: [central])
            if !ok {
                print("Peripheral buffer full while sending fragment; will retry when ready")
                break
            }
        }
    }

    private func startAckTimerForPeripheral(messageId: UInt64, peripheral: CBPeripheral) {
        print("Starting ACK timer for messageId \(messageId) to peripheral \(peripheral.identifier); timeout=\(ackTimeout)s")
        let timer = Timer.scheduledTimer(withTimeInterval: ackTimeout, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let peripheral = peripheral else { return }
            self.retrySendToPeripheral(messageId: messageId, peripheral: peripheral)
        }
        pendingToPeripheral[messageId]?.timer?.invalidate()
        pendingToPeripheral[messageId]?.timer = timer
    }

    private func startAckTimerForCentral(messageId: UInt64, central: CBCentral) {
        print("Starting ACK timer for messageId \(messageId) to central \(central.identifier); timeout=\(ackTimeout)s")
        let timer = Timer.scheduledTimer(withTimeInterval: ackTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.retrySendToCentral(messageId: messageId, central: central)
        }
        pendingToCentral[messageId]?.timer?.invalidate()
        pendingToCentral[messageId]?.timer = timer
    }

    private func retrySendToPeripheral(messageId: UInt64, peripheral: CBPeripheral) {
        guard let pending = pendingToPeripheral[messageId] else { return }
        if pending.retryCount >= maxRetries {
            print("Max retries reached for messageId \(messageId) (to peripheral)")
            if let idx = messages.firstIndex(where: { $0.messageId == messageId }) {
                messages[idx].status = .failed
            }
            pending.timer?.invalidate()
            pendingToPeripheral.removeValue(forKey: messageId)
            return
        }
        pending.retryCount += 1
        print("Retrying messageId \(messageId) to peripheral (attempt \(pending.retryCount))")
        sendFragmentsToPeripheral(peripheral, fragments: pending.fragments)
        startAckTimerForPeripheral(messageId: messageId, peripheral: peripheral)
    }

    private func retrySendToCentral(messageId: UInt64, central: CBCentral) {
        guard let pending = pendingToCentral[messageId] else { return }
        if pending.retryCount >= maxRetries {
            print("Max retries reached for messageId \(messageId) (to central)")
            if let idx = messages.firstIndex(where: { $0.messageId == messageId }) {
                messages[idx].status = .failed
            }
            pending.timer?.invalidate()
            pendingToCentral.removeValue(forKey: messageId)
            return
        }
        pending.retryCount += 1
        print("Retrying messageId \(messageId) to central (attempt \(pending.retryCount))")
        sendFragmentsToCentral(central, fragments: pending.fragments)
        startAckTimerForCentral(messageId: messageId, central: central)
    }

    private func clearPending(for messageId: UInt64) {
        print("clearPending called for messageId: \(messageId)")
        if let p = pendingToPeripheral[messageId] { print("Invalidating peripheral pending timer (retries=\(p.retryCount), fragments=\(p.fragments.count))") }
        if let p = pendingToCentral[messageId] { print("Invalidating central pending timer (retries=\(p.retryCount), fragments=\(p.fragments.count))") }
        if let p = pendingToPeripheral[messageId] {
            p.timer?.invalidate()
            pendingToPeripheral.removeValue(forKey: messageId)
        }
        if let p = pendingToCentral[messageId] {
            p.timer?.invalidate()
            pendingToCentral.removeValue(forKey: messageId)
        }
    }

    func sendMessageToPeripheral(_ peripheral: CBPeripheral, message: String) {
        guard let textData = message.data(using: .utf8) else { return }
        guard let chatChar = chatCharacteristicOnCentral else {
            print("Chat characteristic not found")
            return
        }
        let writeCapacity = peripheral.maximumWriteValueLength(for: .withResponse)
        let maxPayload = Packet.maxPayloadLength(for: writeCapacity)
        let messageId = nextMessageId
        nextMessageId &+= 1
        // Append to UI as sending
        let uiMessage = Message(text: message, isSentByUser: true, status: .sending, messageId: messageId, conversationId: currentConversationId)
        messages.append(uiMessage)
        let packets = Packet.fragmentPayload(textData,
                                             type: .chatMessage,
                                             conversationId: currentConversationId,
                                             messageId: messageId,
                                             maxPayload: maxPayload)
        let fragments = packets.map { $0.encode() }
        for fragment in fragments {
            peripheral.writeValue(fragment, for: chatChar, type: .withResponse)
        }
        let pending = PendingSend(fragments: fragments)
        pendingToPeripheral[messageId] = pending
        startAckTimerForPeripheral(messageId: messageId, peripheral: peripheral)
        print("Sent \(fragments.count) fragment(s) to peripheral for messageId \(messageId)")
    }

    func findChatCharacteristic(peripheral: CBPeripheral) -> CBCharacteristic? {
        // Replace with your logic to find the correct characteristic
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == BluetoothConstants.connectionChatCharacteristicUUID {
                    print("bingo!")
                    return characteristic
                }
            }
        }
        return nil
    }
    
    // update v1
    func sendMessageToCentral(_ central: CBCentral, message: String) {
        guard let textData = message.data(using: .utf8) else { return }
        guard let chatChar = chatCharacteristicOnPeripheral else {
            print("Peripheral chat characteristic not available")
            return
        }
        let writeCapacity = central.maximumUpdateValueLength
        let maxPayload = Packet.maxPayloadLength(for: writeCapacity)
        let messageId = nextMessageId
        nextMessageId &+= 1
        // Append to UI as sending
        let uiMessage = Message(text: message, isSentByUser: true, status: .sending, messageId: messageId, conversationId: currentConversationId)
        messages.append(uiMessage)
        let packets = Packet.fragmentPayload(textData,
                                             type: .chatMessage,
                                             conversationId: currentConversationId,
                                             messageId: messageId,
                                             maxPayload: maxPayload)
        let fragments = packets.map { $0.encode() }
        for fragment in fragments {
            let ok = peripheralManager.updateValue(fragment, for: chatChar, onSubscribedCentrals: [central])
            if !ok {
                print("Peripheral TX buffer full; will retry when ready")
                break
            }
        }
        let pending = PendingSend(fragments: fragments)
        pendingToCentral[messageId] = pending
        startAckTimerForCentral(messageId: messageId, central: central)
        print("Sent \(fragments.count) fragment(s) to central for messageId \(messageId)")
    }
        
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating value for characteristic: \(error.localizedDescription)")
            connectionStatusMessage = "Error receiving response."
            return
        }
        guard let data = characteristic.value else { return }
        print("didUpdateValueFor characteristic \(characteristic.uuid) with \(data.count) bytes")
        // First try to decode as protocol Packet
        if let packet = Packet.decode(data) {
            switch packet.type {
            case .ack:
                if let acked = packet.ackedMessageId() {
                    if seenAckIds.contains(acked) {
                        print("ACK already processed for messageId: \(acked)")
                        return
                    }
                    seenAckIds.insert(acked)
                    print("ACK handling start for messageId: \(acked)")
                    print("Received ACK for messageId \(acked) (central)")
                    clearPending(for: acked)
                    print("Cleared pending for messageId: \(acked)")
                    if let idx = messages.firstIndex(where: { $0.messageId == acked }) {
                        print("Updating UI status to delivered for messageId: \(acked) at index: \(idx)")
                        messages[idx].status = .delivered
                        print("Updated UI status to delivered for messageId: \(acked)")
                    } else {
                        print("No matching UI message found for acked id: \(acked). messages.count=\(messages.count)")
                    }
                }
            case .connectionAccept:
                currentConversationId = packet.conversationId
                connectionStatusMessage = "Accepted"
                awaitingConnectionResponse = false
                // Extract device name from payload if present (sent by peripheral)
                if let deviceName = String(data: packet.payload, encoding: .utf8), !deviceName.isEmpty {
                    self.connectedDeviceName = deviceName
                    print("Received connection accept for conversation \(packet.conversationId), deviceName: \(deviceName)")
                } else {
                    print("Received connection accept for conversation \(packet.conversationId)")
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .chatShouldPresent, object: nil)
                }
            case .connectionDeny:
                currentConversationId = packet.conversationId
                connectionStatusMessage = "Rejected"
                awaitingConnectionResponse = false
                print("Received connection deny for conversation \(packet.conversationId)")
            case .connectionTerminate:
                print("Received terminate packet (central). Cancelling connection")
                connectionStatusMessage = "Terminated"
                remoteChatEnded = true  // Signal to UI before cleanup
                if let p = connectedPeripheral {
                    centralManager.cancelPeripheralConnection(p)
                    connectedPeripheral = nil
                }
                cleanupSession()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .chatShouldDismiss, object: nil)
                }
            case .chatMessage:
                let key = MessageKey(conversationId: packet.conversationId, messageId: packet.messageId)
                if processedKeys.contains(key) { return }
                if let full = reassemblyBuffer.add(packet), let text = String(data: full, encoding: .utf8) {
                    processedKeys.insert(key)
                    let receivedMessage = Message(text: text, isSentByUser: false, status: .delivered, messageId: packet.messageId, conversationId: packet.conversationId)
                    self.messages.append(receivedMessage)
                    // Send ACK back to peripheral
                    if let chatChar = chatCharacteristicOnCentral {
                        let ack = Packet.ack(conversationId: packet.conversationId, ackedMessageId: packet.messageId)
                        let ackData = ack.encode()
                        print("Sending ACK for messageId \(packet.messageId) to peripheral \(peripheral.identifier)")
                        peripheral.writeValue(ackData, for: chatChar, type: .withResponse)
                    }
                }
            case .connectionRequest:
                break
            }
            return
        }
        // Fallback: legacy strings
        if characteristic.uuid == BluetoothConstants.connectionChatCharacteristicUUID {
            print("Received chat characteristic update")
            guard let data = characteristic.value else { return }
            if let packet = Packet.decode(data) {
                switch packet.type {
                case .chatMessage:
                    if let text = String(data: packet.payload, encoding: .utf8) {
                        let receivedMessage = Message(text: text, isSentByUser: false)
                        DispatchQueue.main.async {
                            self.messages.append(receivedMessage)
                        }
                    }
                case .connectionTerminate:
                    print("Received termination packet")
                    // As central, proactively cancel the link
                    if let p = self.connectedPeripheral {
                        self.centralManager.cancelPeripheralConnection(p)
                    }
                    self.cleanupAfterDisconnect()
                    self.restartDiscovery()
                default:
                    break
                }
            } else if let messageText = String(data: data, encoding: .utf8) {
                // Fallback for legacy plain-text messages
                let receivedMessage = Message(text: messageText, isSentByUser: false)
                DispatchQueue.main.async {
                    self.messages.append(receivedMessage)
                }
            }
        } else if let receivedString = String(data: data, encoding: .utf8) {
            if characteristic.uuid == BluetoothConstants.connectionResponseCharacteristicUUID {
                print("Received connection response: \(receivedString)")
                connectionStatusMessage = "Response from \(peripheral.name ?? "Unknown Device"): \(receivedString)"
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error writing value: \(error.localizedDescription)")
        } else {
            print("Value written to characteristic successfully")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating notification state for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == BluetoothConstants.connectionResponseCharacteristicUUID {
            print("Notification state updated for response characteristic. isNotifying=\(characteristic.isNotifying)")
            responseNotifyEnabled = characteristic.isNotifying
            responseNotifyCharacteristicOnCentral = characteristic
            if responseNotifyEnabled, let _ = requestWriteCharacteristic, !didSendConnectionRequest {
                awaitingConnectionResponse = true
                didSendConnectionRequest = true
                sendConnectionRequest(to: peripheral)
                print("Response notify now enabled; sent initial connection request")

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak peripheral] in
                    guard let self = self, let peripheral = peripheral, self.awaitingConnectionResponse else { return }
                    peripheral.readValue(for: characteristic)
                    print("Fallback read of response characteristic (1s) issued")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak peripheral] in
                    guard let self = self, let peripheral = peripheral, self.awaitingConnectionResponse else { return }
                    peripheral.readValue(for: characteristic)
                    print("Fallback read of response characteristic (2s) issued")
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        print("Central willRestoreState: \(dict.keys)")
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restoredPeripherals {
                peripheral.delegate = self
                connectedPeripheral = peripheral
                peripheral.discoverServices([BluetoothConstants.serviceUUID])
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown:
            print("Central Manager state: Unknown")
            isBluetoothPoweredOn = false
        case .resetting:
            print("Central Manager state: Resetting")
            isBluetoothPoweredOn = false
        case .unsupported:
            print("Central Manager state: Unsupported")
            isBluetoothPoweredOn = false
        case .unauthorized:
            print("Central Manager state: Unauthorized")
            isBluetoothPoweredOn = false
        case .poweredOff:
            print("Central Manager state: Powered Off")
            isBluetoothPoweredOn = false
            stopScan()
        case .poweredOn:
            print("Central Manager state: Powered On")
            isBluetoothPoweredOn = true
            startScan()
        @unknown default:
            print("Central Manager state: Unknown default")
            isBluetoothPoweredOn = false
        }
    }
    
    // Discovered peripheral
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Capture the advertised local name (this is the display name set by the other device)
        if let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            peripheralAdvertisedNames[peripheral.identifier] = advertisedName
            print("Advertised local name: \(advertisedName)")
        }

        // Avoid duplicates
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
            let displayName = peripheralAdvertisedNames[peripheral.identifier] ?? peripheral.name ?? "Unknown Device"
            print("Discovered peripheral: \(displayName)")
            if let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool {
                print("isConnectable: \(isConnectable)")
            }
            print("RSSI: \(RSSI)")
        }
    }
    
    // Connected to peripheral
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to peripheral: \(peripheral.name ?? "Unknown Device")")
        // do we need below?
        connectedPeripheral = peripheral
        // Store the peripheral's device name for display (prefer advertised name)
        connectedDeviceName = peripheralAdvertisedNames[peripheral.identifier] ?? peripheral.name
        resetServiceDiscoveryRetries(for: peripheral)
        didSendConnectionRequest = false
        responseNotifyEnabled = false
        peripheral.delegate = self
        peripheral.discoverServices([BluetoothConstants.serviceUUID])
        // Reset conversation identifiers on new connection
        currentConversationId = UUID()
        nextMessageId = 1
    }

    
    // Failed to connect
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect to peripheral: \(peripheral.name ?? "Unknown Device"), Error: \(error?.localizedDescription ?? "No error")")
        connectionStatusMessage = "Failed to connect to \(peripheral.name ?? "Unknown Device")"
    }
    
    // Disconnected from peripheral
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected from peripheral: \(peripheral.name ?? "Unknown Device"), Error: \(error?.localizedDescription ?? "No error")")
        connectionStatusMessage = "Disconnected from \(peripheral.name ?? "Unknown Device")"

        // If WE didn't initiate this disconnect, it means the other device ended the chat
        // Show the "Chat ended" notification (fallback in case termination packet wasn't received)
        if !userInitiatedDisconnect && !remoteChatEnded {
            print("Unexpected disconnect detected - other device likely ended chat")
            remoteChatEnded = true
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .chatShouldDismiss, object: nil)
            }
        }
        userInitiatedDisconnect = false  // Reset for next connection

        connectedPeripheral = nil
        restartDiscovery()
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error.localizedDescription)")
            connectionStatusMessage = "Error discovering services."
            retryServiceDiscovery(for: peripheral)
            return
        }

        guard let services = peripheral.services else {
            print("No services returned; scheduling rediscovery")
            retryServiceDiscovery(for: peripheral)
            return
        }
        if let target = services.first(where: { $0.uuid == BluetoothConstants.serviceUUID }) {
            print("Discovered service: \(target.uuid.uuidString)")
            peripheral.discoverCharacteristics([BluetoothConstants.connectionRequestCharacteristicUUID, BluetoothConstants.connectionResponseCharacteristicUUID, BluetoothConstants.connectionChatCharacteristicUUID], for: target)
        } else {
            print("Target service not found yet; scheduling rediscovery")
            retryServiceDiscovery(for: peripheral)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            connectionStatusMessage = "Error discovering characteristics."
            return
        }
        print("discovering characteristics...")
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            print("Characteristic properties: \(characteristic.properties)")
            if characteristic.uuid == BluetoothConstants.connectionRequestCharacteristicUUID {
                print("Found connection request characteristic: \(characteristic.uuid.uuidString)")
                if characteristic.properties.contains(.write) {
                    requestWriteCharacteristic = characteristic
                    if responseNotifyEnabled {
                        if !didSendConnectionRequest {
                            didSendConnectionRequest = true
                            sendConnectionRequest(to: peripheral)
                            print("Response notify enabled; sent initial connection request")
                        } else {
                            print("Connection request already sent; skipping duplicate send")
                        }
                    } else {
                        print("Response notify not yet enabled; deferring connection request")
                    }
                } else {
                    print("Characteristic does not support writing")
                }
            } 
            if characteristic.uuid == BluetoothConstants.connectionResponseCharacteristicUUID {
                print("Found connection response characteristic, subscribing to notifications")
                responseNotifyCharacteristicOnCentral = characteristic
                // Subscribe to notifications for this characteristic to receive responses from the peripheral
                peripheral.setNotifyValue(true, for: characteristic)
            } 
            if characteristic.uuid == BluetoothConstants.connectionChatCharacteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                chatCharacteristicOnCentral = characteristic
                print("chat char set")
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate
@MainActor extension BluetoothManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .unknown:
            print("Peripheral Manager state: Unknown")
        case .resetting:
            print("Peripheral Manager state: Resetting")
        case .unsupported:
            print("Peripheral Manager state: Unsupported")
        case .unauthorized:
            print("Peripheral Manager state: Unauthorized")
        case .poweredOff:
            print("Peripheral Manager state: Powered Off")
        case .poweredOn:
            print("Peripheral Manager state: Powered On")
            if !servicesAdded {
                startAdvertising()
            }
        @unknown default:
            print("Peripheral Manager state: Unknown default")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        print("Peripheral willRestoreState: \(dict.keys)")
        if let restoredServices = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            servicesAdded = true
            for service in restoredServices where service.uuid == BluetoothConstants.serviceUUID {
                if let characteristics = service.characteristics as? [CBMutableCharacteristic] {
                    for characteristic in characteristics {
                        switch characteristic.uuid {
                        case BluetoothConstants.connectionRequestCharacteristicUUID:
                            requestWriteCharacteristicPeripheral = characteristic
                        case BluetoothConstants.connectionResponseCharacteristicUUID:
                            responseNotifyCharacteristicPeripheral = characteristic
                        case BluetoothConstants.connectionChatCharacteristicUUID:
                            chatCharacteristicOnPeripheral = characteristic
                        default:
                            break
                        }
                    }
                }
            }
        }
        // Ensure advertising is running after restoration
        if !peripheral.isAdvertising {
            peripheral.startAdvertising([
                CBAdvertisementDataLocalNameKey: DisplayNameManager.shared.nameForBLE,
                CBAdvertisementDataServiceUUIDsKey: [BluetoothConstants.serviceUUID]
            ])
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        print("peripheralManagerIsReady; pendingToCentral count: \(pendingToCentral.count)")
        // Attempt to flush any pending sends to central when buffer becomes available
        for (messageId, pending) in pendingToCentral {
            if let central = connectedCentral {
                sendFragmentsToCentral(central, fragments: pending.fragments)
                // Timer continues to run; will be cleared on ACK
            }
        }
        if let pending = pendingResponsePacket, let characteristic = responseNotifyCharacteristicPeripheral {
            let ok: Bool
            if let target = connectionCentral {
                ok = peripheralManager.updateValue(pending, for: characteristic, onSubscribedCentrals: [target])
                print("Flushed pending response packet to central \(target.identifier) (ok=\(ok))")
            } else {
                ok = peripheralManager.updateValue(pending, for: characteristic, onSubscribedCentrals: nil)
                print("Flushed pending response packet to all subscribers (ok=\(ok))")
            }
            if ok { pendingResponsePacket = nil }
        }
    }

    // Track when a central subscribes/unsubscribes to characteristics (e.g., chat notifications)
    // edit v1
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == BluetoothConstants.connectionChatCharacteristicUUID {
            // Store this central to target notifications (chat downlink)
            self.connectedCentral = central
            print("Central subscribed to chat notifications: \(central.identifier)")
        }
        else if characteristic.uuid == BluetoothConstants.connectionResponseCharacteristicUUID {
            print("Central subscribed to response notifications: \(central.identifier)")
            if let pending = pendingResponsePacket, let c = responseNotifyCharacteristicPeripheral {
                let ok = peripheralManager.updateValue(pending, for: c, onSubscribedCentrals: [central])
                print("Sent pending response packet upon subscribe (ok=\(ok))")
                if ok { pendingResponsePacket = nil }
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == BluetoothConstants.connectionChatCharacteristicUUID {
            // Clear if the central unsubscribed from chat notifications
            if self.connectedCentral?.identifier == central.identifier {
                self.connectedCentral = nil
            }
            print("Central unsubscribed from chat notifications: \(central.identifier)")

            // If WE didn't initiate this termination, it means the other device ended the chat
            // Show the "Chat ended" notification (fallback in case termination packet wasn't received)
            if !userInitiatedDisconnect && !remoteChatEnded {
                print("Unexpected unsubscribe detected - other device likely ended chat")
                remoteChatEnded = true
            }
            userInitiatedDisconnect = false  // Reset for next connection

            self.cleanupSession()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .chatShouldDismiss, object: nil)
            }
            restartDiscovery()
        }
    }

    func connectToCentral(_ central: CBCentral) { // connecting peripheral to central
        connectedCentral = central
        // Handle connection logic here
    }

    // Handle incoming write requests
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        print("did receive write")
        for request in requests {
            print("Received write on \(request.characteristic.uuid), length: \(request.value?.count ?? 0)")
            if request.characteristic.uuid == BluetoothConstants.connectionRequestCharacteristicUUID {
                if let requestData = request.value {
                    if let packet = Packet.decode(requestData), packet.type == .connectionRequest {
                        // Establish conversationId from central's request
                        self.currentConversationId = packet.conversationId
                        // Extract device name from payload if present
                        if let deviceName = String(data: packet.payload, encoding: .utf8), !deviceName.isEmpty {
                            self.connectedDeviceName = deviceName
                            print("Received connection request (packet) with conversationId: \(packet.conversationId), deviceName: \(deviceName)")
                        } else {
                            print("Received connection request (packet) with conversationId: \(packet.conversationId)")
                        }
                    } else if let message = String(data: requestData, encoding: .utf8) {
                        // Legacy path
                        print("Received connection request: \(message)")
                    }
                    DispatchQueue.main.async {
                        self.connectionCentral = request.central
                        if self.showAlert == false {
                            self.showAlert = true // trigger SwiftUI alert in ContactsView
                            print("Setting showAlert = true for incoming request")
                            if UIApplication.shared.applicationState != .active {
                                self.scheduleIncomingRequestNotification()
                            }
                        } else {
                            print("Incoming request alert already presented; suppressing duplicate")
                        }
                    }
                }
            }
            else if request.characteristic.uuid == BluetoothConstants.connectionChatCharacteristicUUID {
                if let requestData = request.value {
                    if let packet = Packet.decode(requestData) {
                        switch packet.type {
                        case .chatMessage:
                            let key = MessageKey(conversationId: packet.conversationId, messageId: packet.messageId)
                            if processedKeys.contains(key) {
                                // Already processed; re-send ACK to stop any retries
                                if let chatChar = chatCharacteristicOnPeripheral {
                                    let ack = Packet.ack(conversationId: packet.conversationId, ackedMessageId: packet.messageId)
                                    let ackData = ack.encode()
                                    let ok = peripheralManager.updateValue(ackData, for: chatChar, onSubscribedCentrals: [request.central])
                                    print("Duplicate messageId \(packet.messageId); re-sent ACK to central \(request.central.identifier) (ok=\(ok))")
                                }
                                break
                            }
                            if let full = reassemblyBuffer.add(packet), let text = String(data: full, encoding: .utf8) {
                                processedKeys.insert(key)
                                print("Received message: \(text)")
                                let receivedMessage = Message(text: text, isSentByUser: false)
                                DispatchQueue.main.async {
                                    self.messages.append(receivedMessage)
                                }
                                // Send ACK back to central to confirm delivery
                                if let chatChar = chatCharacteristicOnPeripheral {
                                    let ack = Packet.ack(conversationId: packet.conversationId, ackedMessageId: packet.messageId)
                                    let ackData = ack.encode()
                                    let ok = peripheralManager.updateValue(ackData, for: chatChar, onSubscribedCentrals: [request.central])
                                    print("Sent ACK for messageId \(packet.messageId) to central \(request.central.identifier) (ok=\(ok))")
                                }
                            }
                        case .connectionTerminate:
                            print("Received termination packet from central")
                            self.remoteChatEnded = true  // Signal to UI before cleanup
                            // Peripheral cannot cancel the connection directly; central will typically cancel.
                            self.cleanupAfterDisconnect()
                            self.restartDiscovery()
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .chatShouldDismiss, object: nil)
                            }
                        default:
                            break
                        }
                    } else if let message = String(data: requestData, encoding: .utf8) {
                        print("Received message: \(message)")
                        let receivedMessage = Message(text: message, isSentByUser: false)
                        DispatchQueue.main.async {
                            self.messages.append(receivedMessage)
                        }
                    }
                }
            }
        }
        // does enter
        // Respond to the write request
        for request in requests {
            print("entering")
            let central = request.central  // This gets the central device making the request
            // Call the function to handle the connection with this central
            self.connectToCentral(central)
            peripheralManager.respond(to: request, withResult: .success)

        }
    }

    func respondToConnectionRequest(accepted: Bool) {
        let value = accepted ? PacketType.connectionAccept : PacketType.connectionDeny
        responseStatusMessage = accepted ? "Accepted" : "Rejected"
        // Include display name in accept payload so central can display it
        let payload: Data
        if accepted {
            let displayName = DisplayNameManager.shared.nameForBLE
            payload = displayName.data(using: .utf8) ?? Data()
        } else {
            payload = Data()
        }
        let packet = Packet(type: value,
                            conversationId: currentConversationId,
                            messageId: 0,
                            fragmentIndex: 0,
                            fragmentCount: 1,
                            payload: payload)
        if let characteristic = responseNotifyCharacteristicPeripheral {
            let data = packet.encode()
            var ok = false
            if let target = connectionCentral {
                ok = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: [target])
                print("Sent response packet: \(value) to central \(target.identifier) with conversationId: \(currentConversationId) (ok=\(ok))")
            } else {
                ok = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
                print("Sent response packet: \(value) to all subscribed centrals with conversationId: \(currentConversationId) (ok=\(ok))")
            }
            if !ok {
                pendingResponsePacket = data
                print("Response notify buffer full or no subscribers; queued pending response packet")
            } else {
                pendingResponsePacket = nil
            }
        }
        if accepted {
            // No connect back; central maintains the connection
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("Error adding service: \(error.localizedDescription)")
            return
        }

        // Service was added, now start advertising
        servicesAdded = true
        peripheralManager.startAdvertising([
                CBAdvertisementDataLocalNameKey: DisplayNameManager.shared.nameForBLE,
                CBAdvertisementDataServiceUUIDsKey: [BluetoothConstants.serviceUUID]
            ])

        //peripheralManager.startAdvertising(advertisementData)
        print("Started advertising with service UUID: \(BluetoothConstants.serviceUUID.uuidString)")
    }

    @objc private func handleChatDidDismissNotification(_ notification: Notification) {
        print("Chat dismissal notification received; terminating chat and returning to discovery")
        terminateChat()
    }
}

// MARK: - Connection Handling
extension BluetoothManager {
    func acceptConnectionRequest() {
        print("acceptConnectionRequest() tapped; sending Accepted response")
        guard let central = connectionCentral else {
            print("No central to respond to.")
            return
        }
        respondToConnectionRequest(accepted: true)
        connectionStatusMessage = "Accepted connection request from \(central.identifier.uuidString)"
    }
    
    func rejectConnectionRequest() {
        print("rejectConnectionRequest() tapped; sending Rejected response")
        guard let central = connectionCentral else {
            print("No central to respond to.")
            return
        }
        respondToConnectionRequest(accepted: false)
        connectionStatusMessage = "Rejected connection request from \(central.identifier.uuidString)"
    }

    /// Call this after showing the "Chat ended" notification to reset the flag
    func acknowledgeRemoteChatEnded() {
        remoteChatEnded = false
    }
}

// MARK: - Termination & Utilities
extension BluetoothManager {
    private func makePacket(type: PacketType, payload: Data = Data()) -> Data {
        let pkt = Packet(type: type,
                         conversationId: currentConversationId,
                         messageId: nextMessageId,
                         fragmentIndex: 0,
                         fragmentCount: 1,
                         payload: payload)
        nextMessageId &+= 1
        return pkt.encode()
    }

    func terminateChat() {
        let payload = Data()
        // If acting as central, write termination to peripheral and cancel
        if let peripheral = connectedPeripheral, let chatChar = chatCharacteristicOnCentral {
            let data = makePacket(type: .connectionTerminate, payload: payload)
            peripheral.writeValue(data, for: chatChar, type: .withResponse)
            centralManager.cancelPeripheralConnection(peripheral)
        }
        // If acting as peripheral, notify the subscribed central
        if let central = connectedCentral, let chatChar = chatCharacteristicOnPeripheral {
            let data = makePacket(type: .connectionTerminate, payload: payload)
            _ = peripheralManager.updateValue(data, for: chatChar, onSubscribedCentrals: [central])
        }
        cleanupAfterDisconnect()
        restartDiscovery()
    }
    private func cleanupAfterDisconnect() {
        connectedPeripheral = nil
        connectedCentral = nil
        connectionCentral = nil
        // Clear central-side characteristic references (will be rediscovered on next connection)
        requestWriteCharacteristic = nil
        chatCharacteristicOnCentral = nil
        responseNotifyCharacteristicOnCentral = nil
        // DO NOT clear peripheral-side characteristic references - they persist with the GATT service
        // and clearing them breaks subsequent connections
        didSendConnectionRequest = false
        responseNotifyEnabled = false
        showAlert = false
        // Reset status messages so onChange can fire on next connection
        connectionStatusMessage = ""
        responseStatusMessage = ""
        // Clear connected device name
        connectedDeviceName = nil
        // Clear messages per ephemeral chat requirement
        messages.removeAll()
    }

    private func restartDiscovery() {
        if centralManager.state == .poweredOn {
            stopScan()
            startScan()
        }
        if peripheralManager.state == .poweredOn {
            stopAdvertising()
            startAdvertising()
        }
    }

    /// Restarts advertising to pick up any display name changes
    func restartAdvertisingForNameChange() {
        if peripheralManager.state == .poweredOn {
            stopAdvertising()
            startAdvertising()
            print("Restarted advertising with updated display name: \(DisplayNameManager.shared.nameForBLE)")
        }
    }

    /// Returns the display name for a peripheral, preferring the advertised name over the system name
    func displayName(for peripheral: CBPeripheral) -> String {
        return peripheralAdvertisedNames[peripheral.identifier] ?? peripheral.name ?? "Unknown Device"
    }
}

