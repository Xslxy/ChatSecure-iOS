//
//  OTRXMPPMessageYapStroage.m
//  ChatSecure
//
//  Created by David Chiles on 8/13/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "OTRXMPPMessageYapStroage.h"
#import "XMPPStream.h"
#import "XMPPMessage+XEP_0085.h"
#import "XMPPMessage+XEP_0184.h"
#import "XMPPMessage+XEP_0280.h"
#import "NSXMLElement+XEP_0203.h"
#import "OTRLog.h"
@import OTRKit;
#import "OTRXMPPBuddy.h"
#import "OTRMessage.h"
#import "OTRAccount.h"
#import "OTRConstants.h"
#import <ChatSecureCore/ChatSecureCore-Swift.h>
#import "OTRThreadOwner.h"

@implementation OTRXMPPMessageYapStroage

- (instancetype)initWithDatabaseConnection:(YapDatabaseConnection *)connection
{
    if (self = [self init]) {
        _databaseConnection = connection;
        _moduleDelegateQueue = dispatch_queue_create("OTRXMPPMessageYapStroage-delegateQueue", 0);
    }
    return self;
}


- (OTRXMPPBuddy *)buddyForUsername:(NSString *)username stream:(XMPPStream *)stream transaction:(YapDatabaseReadTransaction *)transaction
{
    return [OTRXMPPBuddy fetchBuddyWithUsername:username withAccountUniqueId:stream.tag transaction:transaction];
}

- (OTRMessage *)messageFromXMPPMessage:(XMPPMessage *)xmppMessage buddyId:(NSString *)buddyId
{
    NSString *body = [xmppMessage body];
    
    NSDate * date = [xmppMessage delayedDeliveryDate];
    
    OTRMessage *message = [[OTRMessage alloc] init];
    message.incoming = YES;
    message.text = body;
    message.buddyUniqueId = buddyId;
    if (date) {
        message.date = date;
    }
    
    message.messageId = [xmppMessage elementID];
    return message;
}

- (OTROutgoingMessage *)outgoingMessageFromXMPPMessage:(XMPPMessage *)xmppMessage buddyId:(NSString *)buddyId {
    OTROutgoingMessage *outgoingMessage = (OTROutgoingMessage *)[self baseMessageFromXMPPMessage:xmppMessage buddyId:buddyId class:[OTROutgoingMessage class]];
    // Fill in current data so it looks like this 'outgoing' message was really sent (but of course this is a message we received through carbons).
    outgoingMessage.dateSent = [NSDate date];
    return outgoingMessage;
}

- (OTRIncomingMessage *)incomingMessageFromXMPPMessage:(XMPPMessage *)xmppMessage buddyId:(NSString *)buddyId
{
    return (OTRIncomingMessage *)[self baseMessageFromXMPPMessage:xmppMessage buddyId:buddyId class:[OTRIncomingMessage class]];
}

- (void)xmppStream:(XMPPStream *)stream didReceiveMessage:(XMPPMessage *)xmppMessage
{
    // We don't handle incoming group chat messages here
    // Check out OTRXMPPRoomYapStorage instead
    if ([[xmppMessage type] isEqualToString:@"groupchat"] ||
        [xmppMessage elementForName:@"x" xmlns:XMPPMUCUserNamespace] ||
        [xmppMessage elementForName:@"x" xmlns:@"jabber:x:conference"]) {
        return;
    }
    
    if ([xmppMessage isMessageCarbon]) {
        return;
    }
    
    [self.databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        
        if ([stream.tag isKindOfClass:[NSString class]]) {
            NSString *username = [[xmppMessage from] bare];
            
            [self handleChatState:xmppMessage username:username stream:stream transaction:transaction];
            [self handleDeliverResponse:xmppMessage transaction:transaction];
            
            OTRXMPPBuddy *messageBuddy = [OTRXMPPBuddy fetchBuddyWithUsername:username withAccountUniqueId:stream.tag transaction:transaction];
            if (!messageBuddy) {
                // message from server
                DDLogWarn(@"No buddy for message: %@", xmppMessage);
                return;
            }
            
            OTRMessage *message = [self messageFromXMPPMessage:xmppMessage buddyId:messageBuddy.uniqueId];
            message.incoming = YES;
            id<OTRThreadOwner>activeThread = [[OTRAppDelegate appDelegate] activeThread];
            if([[activeThread threadIdentifier] isEqualToString:message.threadId]) {
                message.read = YES;
            }
            OTRAccount *account = [OTRAccount fetchObjectWithUniqueID:xmppStream.tag transaction:transaction];
            
            
            if ([xmppMessage isErrorMessage]) {
                NSError *error = [xmppMessage errorMessage];
                message.error = error;
                NSString *errorText = [[xmppMessage elementForName:@"error"] elementForName:@"text"].stringValue;
                if (!message.text) {
                    if (errorText) {
                        message.text = errorText;
                    } else {
                        message.text = error.localizedDescription;
                    }
                }
                if ([errorText containsString:@"OTR Error"]) {
                    // automatically renegotiate a new session when there's an error
                    [[OTRKit sharedInstance] initiateEncryptionWithUsername:username accountName:account.username protocol:account.protocolTypeString];
                }
                // Suppress error messages for now...
                // [message saveWithTransaction:transaction];
                return;
            }
            
            if ([self duplicateMessage:xmppMessage buddyUniqueId:messageBuddy.uniqueId transaction:transaction]) {
                DDLogWarn(@"Duplicate message received: %@", xmppMessage);
                return;
            }
            
            if (message.text) {
                [[OTRKit sharedInstance] decodeMessage:message.text username:messageBuddy.username accountName:account.username protocol:kOTRProtocolTypeXMPP tag:message];
            }
        }
    }];
}

- (void)handleChatState:(XMPPMessage *)xmppMessage username:(NSString *)username stream:(XMPPStream *)stream transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OTRXMPPBuddy *messageBuddy = [OTRXMPPBuddy fetchBuddyWithUsername:username withAccountUniqueId:stream.tag transaction:transaction];
    if([xmppMessage hasChatState])
    {
        if([xmppMessage hasComposingChatState])
            messageBuddy.chatState = kOTRChatStateComposing;
        else if([xmppMessage hasPausedChatState])
            messageBuddy.chatState = kOTRChatStatePaused;
        else if([xmppMessage hasActiveChatState])
            messageBuddy.chatState = kOTRChatStateActive;
        else if([xmppMessage hasInactiveChatState])
            messageBuddy.chatState = kOTRChatStateInactive;
        else if([xmppMessage hasGoneChatState])
            messageBuddy.chatState = kOTRChatStateGone;
        [messageBuddy saveWithTransaction:transaction];
    }
}

- (void)handleDeliverResponse:(XMPPMessage *)xmppMessage transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    if ([xmppMessage hasReceiptResponse] && ![xmppMessage isErrorMessage]) {
        [OTRMessage receivedDeliveryReceiptForMessageId:[xmppMessage receiptResponseID] transaction:transaction];
    }
}

- (BOOL)duplicateMessage:(XMPPMessage *)message buddyUniqueId:(NSString *)buddyUniqueId transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    __block BOOL result = NO;
    if ([message.elementID length]) {
        [transaction enumerateMessagesWithId:message.elementID block:^(id<OTRMessageProtocol> _Nonnull databaseMessage, BOOL * _Null_unspecified stop) {
            if ([[databaseMessage threadId] isEqualToString:buddyUniqueId]) {
                *stop = YES;
                result = YES;
            }
        }];
    }
    return result;
}

- (void)handleCarbonMessage:(XMPPMessage *)forwardedMessage stream:(XMPPStream *)stream outgoing:(BOOL)isOutgoing
{
    //Sent Message Carbons are sent by our account to another
    //So from is our JID and to is buddy
    BOOL incoming = !isOutgoing;
    
    NSString *username = nil;
    if (incoming) {
        username = [[forwardedMessage from] bare];
    } else {
        username = [[forwardedMessage to] bare];
    }
    
    [self.databaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction * __nonnull transaction) {
        
        OTRXMPPBuddy *buddy = [OTRXMPPBuddy fetchBuddyForUsername:username accountName:stream.tag transaction:transaction];
        
        if (buddy) {
            if (![self duplicateMessage:forwardedMessage buddyUniqueId:buddy.uniqueId transaction:transaction]) {
                if (incoming) {
                    [self handleChatState:forwardedMessage username:username stream:stream transaction:transaction];
                    [self handleDeliverResponse:forwardedMessage transaction:transaction];
                }
                
                
                
                if ([forwardedMessage isMessageWithBody] && ![forwardedMessage isErrorMessage] && ![OTRKit stringStartsWithOTRPrefix:forwardedMessage.body]) {
                    OTRMessage *message = [self messageFromXMPPMessage:forwardedMessage buddyId:buddy.uniqueId];
                    message.incoming = incoming;
                    id<OTRThreadOwner>activeThread = [[OTRAppDelegate appDelegate] activeThread];
                    if([[activeThread threadIdentifier] isEqualToString:message.threadId]) {
                        message.read = YES;
                    }
                    [message saveWithTransaction:transaction];
                }
            }
        }
    }];
}

#pragma - mark XMPPMessageCarbonsDelegate

- (void)xmppMessageCarbons:(XMPPMessageCarbons *)xmppMessageCarbons didReceiveMessage:(XMPPMessage *)message outgoing:(BOOL)isOutgoing
{
    [self handleCarbonMessage:message stream:xmppMessageCarbons.xmppStream outgoing:isOutgoing];
}

@end
