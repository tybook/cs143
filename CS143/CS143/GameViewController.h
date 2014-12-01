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

@property (assign, nonatomic) bool raft_periodic_started;

- (void)proposeData:(NSData *) data;
- (void) raft_start_periodic;

@end
