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

-(void)clearScene
{
    [self removeAllChildren];
}

-(void)startGame
{
    // Set the raft configuration and start raft_periodic
    // This will send RequestVote messages, so other devices will
    // know that someone has started the game
    [self.gameView raft_start];
    
    
    // hide the start button and show the clear button
    self.resetButton.hidden = NO;
    self.startButton.hidden = YES;
    self.connectedLabel.hidden = YES;
}

-(void)handleConnected: (NSUInteger) numConnected
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
    [self.resetButton addTarget:self action:@selector(clearScene) forControlEvents:UIControlEventTouchUpInside];
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
    
    // If raft_periodic has not started, start it now
    /*if (!self.gameView.raft_periodic_started)
    {
        [self.gameView raft_start_periodic];
        return;
    }*/
    
    for (UITouch *touch in touches) {
        CGPoint location = [touch locationInNode:self];
        
        // Propose a client action
        [self.gameView proposeData:location];
        
        //[self drawTouch:location];
    }
}

-(void)drawTouch:(CGPoint)coors
{
    SKSpriteNode *sprite = [SKSpriteNode spriteNodeWithImageNamed:@"Spaceship"];
    
    sprite.xScale = 0.2;
    sprite.yScale = 0.2;
    sprite.position = coors;
    
    SKAction *action = [SKAction rotateByAngle:M_PI duration:1];
    
    [sprite runAction:[SKAction repeatActionForever:action]];
    
    [self addChild:sprite];
}

-(void)update:(CFTimeInterval)currentTime {
    /* Called before each frame is rendered */
}

@end