import Foundation

/// Packet types used by the BLE chat protocol.
public enum PacketType: UInt8 {
    case connectionRequest = 0x01
    case connectionAccept  = 0x02
    case connectionDeny    = 0x03
    case connectionTerminate = 0x04
    case chatMessage       = 0x10
    case ack               = 0x20
}

/// Minimal packet envelope for BLE messages with fragmentation support.
public struct Packet {
    public static let versionCurrent: UInt8 = 1
    public static let headerLength: Int = 1 /*version*/ + 1 /*type*/ + 16 /*UUID*/ + 8 /*messageId*/ + 2 /*fragIndex*/ + 2 /*fragCount*/

    public var version: UInt8 = Packet.versionCurrent
    public var type: PacketType
    public var conversationId: UUID
    public var messageId: UInt64
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16
    public var payload: Data

    public init(version: UInt8 = Packet.versionCurrent,
                type: PacketType,
                conversationId: UUID,
                messageId: UInt64,
                fragmentIndex: UInt16,
                fragmentCount: UInt16,
                payload: Data) {
        self.version = version
        self.type = type
        self.conversationId = conversationId
        self.messageId = messageId
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payload = payload
    }
}

public extension Packet {
    /// Encode the packet into a Data buffer suitable for BLE transmission.
    func encode() -> Data {
        var data = Data(capacity: Packet.headerLength + payload.count)
        data.append(version)
        data.append(type.rawValue)
        // UUID bytes (16)
        var uuid = conversationId.uuid
        withUnsafeBytes(of: &uuid) { rawBuf in
            data.append(rawBuf.bindMemory(to: UInt8.self))
        }
        // messageId (8 bytes, big-endian)
        var msgBE = messageId.bigEndian
        withUnsafeBytes(of: &msgBE) { rawBuf in
            data.append(rawBuf.bindMemory(to: UInt8.self))
        }
        // fragmentIndex (2 bytes, big-endian)
        var fragIndexBE = fragmentIndex.bigEndian
        withUnsafeBytes(of: &fragIndexBE) { rawBuf in
            data.append(rawBuf.bindMemory(to: UInt8.self))
        }
        // fragmentCount (2 bytes, big-endian)
        var fragCountBE = fragmentCount.bigEndian
        withUnsafeBytes(of: &fragCountBE) { rawBuf in
            data.append(rawBuf.bindMemory(to: UInt8.self))
        }
        // payload
        data.append(payload)
        print("Packet.encode type: \(type) msgId: \(messageId) frag: \(fragmentIndex+1)/\(fragmentCount) payloadLen: \(payload.count)")
        return data
    }

    /// Decode a packet from a Data buffer. Returns nil if the buffer is malformed.
    static func decode(_ data: Data) -> Packet? {
        var offset = 0
        if data.count < Packet.headerLength {
            print("Packet.decode abort: too short (\(data.count) < \(Packet.headerLength))")
            return nil
        }
        // version
        let version = data[offset]; offset += 1
        // type
        guard let type = PacketType(rawValue: data[offset]) else { return nil }
        offset += 1
        // UUID (16 bytes)
        if data.count < offset + 16 { print("Packet.decode abort: missing UUID bytes") ; return nil }
        let u0 = data[offset]; let u1 = data[offset+1]; let u2 = data[offset+2]; let u3 = data[offset+3]
        let u4 = data[offset+4]; let u5 = data[offset+5]; let u6 = data[offset+6]; let u7 = data[offset+7]
        let u8 = data[offset+8]; let u9 = data[offset+9]; let u10 = data[offset+10]; let u11 = data[offset+11]
        let u12 = data[offset+12]; let u13 = data[offset+13]; let u14 = data[offset+14]; let u15 = data[offset+15]
        let uuid = UUID(uuid: (u0, u1, u2, u3, u4, u5, u6, u7, u8, u9, u10, u11, u12, u13, u14, u15))
        offset += 16
        // messageId (8 bytes, big-endian)
        if data.count < offset + 8 { print("Packet.decode abort: missing messageId bytes") ; return nil }
        var messageId: UInt64 = 0
        for i in 0..<8 { messageId = (messageId << 8) | UInt64(data[offset + i]) }
        offset += 8
        // fragmentIndex (2 bytes, big-endian)
        if data.count < offset + 2 { print("Packet.decode abort: missing fragmentIndex bytes") ; return nil }
        let fragmentIndex = (UInt16(data[offset]) << 8) | UInt16(data[offset+1])
        offset += 2
        // fragmentCount (2 bytes, big-endian)
        if data.count < offset + 2 { print("Packet.decode abort: missing fragmentCount bytes") ; return nil }
        let fragmentCount = (UInt16(data[offset]) << 8) | UInt16(data[offset+1])
        offset += 2
        // payload (rest)
        let payload = data.suffix(from: offset)
        let packet = Packet(version: version,
                            type: type,
                            conversationId: uuid,
                            messageId: messageId,
                            fragmentIndex: fragmentIndex,
                            fragmentCount: fragmentCount,
                            payload: payload)
        print("Packet.decode type: \(packet.type) msgId: \(packet.messageId) frag: \(packet.fragmentIndex+1)/\(packet.fragmentCount) payloadLen: \(packet.payload.count)")
        return packet
    }

    /// Helper to compute the maximum payload given an MTU (or write length).
    static func maxPayloadLength(for writeCapacity: Int) -> Int {
        return max(0, writeCapacity - Packet.headerLength)
    }

    /// Build an ACK packet for a given conversation and messageId.
    static func ack(conversationId: UUID, ackedMessageId: UInt64) -> Packet {
        var be = ackedMessageId.bigEndian
        let payload = withUnsafeBytes(of: &be) { Data($0) }
        return Packet(type: .ack,
                      conversationId: conversationId,
                      messageId: ackedMessageId,
                      fragmentIndex: 0,
                      fragmentCount: 1,
                      payload: payload)
    }

    /// If this is an ACK packet, return the acked message id.
    func ackedMessageId() -> UInt64? {
        guard type == .ack else { return nil }
        guard payload.count >= 8 else {
            print("ACK payload too short: \(payload.count) bytes")
            return nil
        }
        var value: UInt64 = 0
        // Use safe indexing and bounds checking
        for i in 0..<8 {
            value = (value << 8) | UInt64(payload[payload.startIndex.advanced(by: i)])
        }
        return value
    }

    /// Fragment a payload into multiple packets.
    static func fragmentPayload(_ payload: Data,
                                type: PacketType,
                                conversationId: UUID,
                                messageId: UInt64,
                                maxPayload: Int) -> [Packet] {
        guard maxPayload > 0 else { return [] }
        if payload.isEmpty {
            return [Packet(type: type,
                           conversationId: conversationId,
                           messageId: messageId,
                           fragmentIndex: 0,
                           fragmentCount: 1,
                           payload: Data())]
        }
        let totalFragments = UInt16((payload.count + maxPayload - 1) / maxPayload)
        var packets: [Packet] = []
        packets.reserveCapacity(Int(totalFragments))
        var index: UInt16 = 0
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxPayload, payload.count)
            let chunk = payload[offset..<end]
            packets.append(Packet(type: type,
                                  conversationId: conversationId,
                                  messageId: messageId,
                                  fragmentIndex: index,
                                  fragmentCount: totalFragments,
                                  payload: Data(chunk)))
            offset = end
            index &+= 1
        }
        return packets
    }
}

/// Key for tracking reassembly state.
public struct MessageKey: Hashable {
    public let conversationId: UUID
    public let messageId: UInt64
    public init(conversationId: UUID, messageId: UInt64) {
        self.conversationId = conversationId
        self.messageId = messageId
    }
}

/// Simple in-memory reassembly buffer.
public final class ReassemblyBuffer {
    private struct Entry {
        var expectedCount: UInt16
        var fragments: [UInt16: Data] // fragmentIndex -> payload
    }

    private var storage: [MessageKey: Entry] = [:]

    public init() {}

    /// Add a packet. Returns the full reassembled payload if complete; otherwise nil.
    public func add(_ packet: Packet) -> Data? {
        let key = MessageKey(conversationId: packet.conversationId, messageId: packet.messageId)
        var entry = storage[key] ?? Entry(expectedCount: packet.fragmentCount, fragments: [:])
        entry.expectedCount = max(entry.expectedCount, packet.fragmentCount)
        entry.fragments[packet.fragmentIndex] = packet.payload
        storage[key] = entry

        if entry.fragments.count == Int(entry.expectedCount) {
            // Reassemble in order
            var result = Data()
            for i in 0..<entry.expectedCount {
                guard let chunk = entry.fragments[i] else { return nil }
                result.append(chunk)
            }
            storage.removeValue(forKey: key)
            return result
        }
        return nil
    }

    public func clear(conversationId: UUID, messageId: UInt64) {
        let key = MessageKey(conversationId: conversationId, messageId: messageId)
        storage.removeValue(forKey: key)
    }

    public func removeAll() {
        storage.removeAll()
    }
}

