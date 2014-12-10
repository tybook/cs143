//
//  RaftBLE.h
//  CS143
//
//  Created by Ty Book on 12/10/14.
//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol RaftBLEDelegate

- (void) applyLog: (unsigned char *)entry;

@end


@interface RaftBLE : NSObject

- (void) proposeLog: (unsigned char *)entry;

@property (nonatomic, weak) id <RaftBLEDelegate> delegate;

@end
