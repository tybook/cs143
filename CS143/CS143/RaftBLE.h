//
//  RaftBLE.h
//  CS143
//
//  Created by Ty Book on 12/10/14.
//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol RaftBLEDelegate

// The given entry can safely be committed
- (void) applyLog: (unsigned char*)entry;

// another device started the game
- (void) gameStarted;

- (void) numConnectedDevicesChanged: (NSUInteger)numConnected;

@end


@interface RaftBLE : NSObject

// Propose an entry
- (void) proposeLog: (unsigned char *)data length:(int)len;

/* Set up the raft configuration based on the currently connected devices.
 Start periodic calls to update raft state */
- (void)raft_start: (int) startCandidate;

- (id)initWithDelegate:(id<RaftBLEDelegate>)delegate;

@property (nonatomic, weak) id <RaftBLEDelegate> delegate;

@end
