//
//  Message.swift
//  ProxC
//
//  Created by Manuel Hidalgo Sola on 9/11/24.
//

import Foundation
import SwiftUI

enum MessageStatus: String, Codable {
    case sending
    case delivered
    case failed
}

struct Message: Identifiable, Codable {
    var id = UUID()
    var text: String
    var isSentByUser: Bool // True if sent by user, False if received
    var status: MessageStatus = .delivered // default delivered for received messages
    var messageId: UInt64? = nil
    var conversationId: UUID? = nil
}
