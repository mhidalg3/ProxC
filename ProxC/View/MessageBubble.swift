//
//  MessageBubble.swift
//  ProxC
//
//  Created by Manuel Hidalgo Sola on 9/4/24.
//

import SwiftUI

struct MessageBubble: View {
    var message: Message
    
    var body: some View {
        HStack {
            if message.isSentByUser {
                Spacer() // Push the user's messages to the right
            }
            
            Text(message.text)
                .padding(10)
                .background(message.isSentByUser ? Color.black : Color.gray.opacity(0.2)) // Black for user, gray for contact
                .foregroundColor(message.isSentByUser ? Color.white : Color.black) // White text for user, black for contact
                .cornerRadius(10)
                .frame(maxWidth: 250, alignment: message.isSentByUser ? .trailing : .leading)
            
            if !message.isSentByUser {
                Spacer() // Push the contact's messages to the left
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
}


