//
//  GameViewController.h
//  CS143
//

//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import <CoreBluetooth/CoreBluetooth.h>


@interface GameViewController : UIViewController

- (void)proposeData:(NSData *) data;

/* Set up the raft configuration based on the currently connected devices.
   Start periodic calls to update raft state */
- (void)raft_start;

//+ (id) sharedController;

@end
