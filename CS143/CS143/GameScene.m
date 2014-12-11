//
//  GameScene.m
//  CS143
//
//  Created by Ty Book on 11/28/14.
//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import "GameScene.h"
#import "GameViewController.h"

GameViewController *gameView;

@interface GameScene ()

@property (weak, nonatomic) GameViewController *gameView;
@property (strong, nonatomic) UIButton *startButton;
@property (strong, nonatomic) UIButton *resetButton;
@property (strong, nonatomic) UILabel *connectedLabel;

@end

@implementation GameScene

-(void)clearPressed
{
    // Propose a value at location (-1, -1)
    CGPoint location = CGPointMake(-1, -1);
    [self.gameView proposeData:location];
}

-(void)startGame
{
    [self.gameView start_raft];
    [self gameStarted];
}

-(void)gameStarted
{
    // hide the start button and show the clear button
    self.resetButton.hidden = NO;
    self.startButton.hidden = YES;
    self.connectedLabel.hidden = YES;
}

-(void)numConnectedDevicesChanged:(NSUInteger)numConnected
{
    self.connectedLabel.text = [NSString stringWithFormat:@"%lu Connected", (unsigned long)numConnected];
}

-(void)didMoveToView:(SKView *)view {
    self.gameView = (GameViewController *)[[[[UIApplication sharedApplication] delegate] window] rootViewController];
    
    /* Setup your scene here */
    self.startButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    self.startButton.titleLabel.font = [UIFont systemFontOfSize:16];
    CGFloat width = 100;
    CGFloat height = 50;
    [self.startButton setFrame:CGRectMake((self.view.frame.size.width - width)/2,
                                     (self.view.frame.size.height - height)/2, width, height)];
    [self.startButton setTitle:@"Start" forState:UIControlStateNormal];
    [self.startButton addTarget:self action:@selector(startGame) forControlEvents:UIControlEventTouchUpInside];
    self.startButton.hidden = NO;
    [self.view addSubview:self.startButton];
    
    self.resetButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    self.resetButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [self.resetButton setFrame:CGRectMake((self.view.frame.size.width - width)/2,
                                     self.view.frame.size.height - 75, width, height)];
    [self.resetButton setTitle:@"Reset" forState:UIControlStateNormal];
    [self.resetButton addTarget:self action:@selector(clearPressed) forControlEvents:UIControlEventTouchUpInside];
    self.resetButton.hidden = YES;
    [self.view addSubview:self.resetButton];
    
    self.connectedLabel = [[UILabel alloc]initWithFrame:CGRectMake((self.view.frame.size.width - width)/2,
                                                                   (self.view.frame.size.height - height)/2 + 50, width, height)];
    self.connectedLabel.text = @"0 Connected";
    [self.view addSubview:self.connectedLabel];

}

-(void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    /* Called when a touch begins */
    if (self.startButton.hidden == NO)
        return;
        
    for (UITouch *touch in touches) {
        CGPoint location = [touch locationInNode:self];
        
        // Propose a client action
        
        [self.gameView proposeData:location];
        
        //[self drawTouch:location];
    }
}

-(void)drawTouch:(CGPoint)coors
{
    if (coors.x == -1 && coors.y == -1) {
        // clear the scene
        [self removeAllChildren];
        return;
    }
    SKSpriteNode *sprite = [SKSpriteNode spriteNodeWithImageNamed:@"Spaceship"];
    
    sprite.xScale = 0.2;
    sprite.yScale = 0.2;
    sprite.position = coors;
    
    SKAction *action = [SKAction rotateByAngle:M_PI duration:1];
    
    [sprite runAction:[SKAction repeatActionForever:action]];
    
    [self addChild:sprite];
}

-(void)applyLog:(unsigned char *)entry
{
    CGFloat x = *(CGFloat*)entry;
    CGFloat y = *((CGFloat*)entry + 1);

    [self drawTouch:CGPointMake(x, y)];
}


-(void)update:(CFTimeInterval)currentTime {
    /* Called before each frame is rendered */
}

@end