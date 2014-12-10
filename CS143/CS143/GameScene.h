//
//  GameScene.h
//  CS143
//

//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import <SpriteKit/SpriteKit.h>
#import "RaftBLE.h"

@interface GameScene : SKScene <RaftBLEDelegate>

// This will also start the raft server
-(void)startGame:(int)startCandidate;

-(void)drawTouch: (CGPoint) coors;
-(void)handleConnected: (NSUInteger) numConnected;

@end
