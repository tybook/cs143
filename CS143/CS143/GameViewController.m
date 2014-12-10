//
//  GameViewController.m
//  CS143
//
//  Created by Ty Book on 11/28/14.
//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import "GameViewController.h"
#import "GameScene.h"
#import "RaftBLE.h"

@implementation SKScene (Unarchive)

+ (instancetype)unarchiveFromFile:(NSString *)file {
    /* Retrieve scene file path from the application bundle */
    NSString *nodePath = [[NSBundle mainBundle] pathForResource:file ofType:@"sks"];
    /* Unarchive the file to an SKScene object */
    NSData *data = [NSData dataWithContentsOfFile:nodePath
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    NSKeyedUnarchiver *arch = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
    [arch setClass:self forClassName:@"SKScene"];
    SKScene *scene = [arch decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [arch finishDecoding];
    
    return scene;
}

@end

@interface GameViewController () <CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate>

@property (strong, nonatomic) GameScene             *scene;

@end

@implementation GameViewController

/*
+ (id)sharedController {
    static GameViewController *sharedController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedController = [[self alloc] init];
    });
    return sharedController;
}

- (id)init {
    if (self = [super init]) {
        initialize instance variables here
    }
    return self;
}*/

-(void)proposeData:(CGPoint)point
{
    msg_entry_t msg;
    msg.data[0] = point.x;
    msg.data[1] = point.y;
    
    if (raft_is_leader(raft_server)) {
        raft_recv_entry(raft_server, 0, &msg);
    }
    else {
        NSData *data = [NSData dataWithBytes:&msg length:sizeof(msg_entry_t)];
        [self.peripheralManager updateValue:data forCharacteristic:self.proposeCharacteristic onSubscribedCentrals:nil];
    }
}

- (void) raft_call_periodic
{
    raft_periodic(raft_server, RAFT_PERIODIC_SEC*1000);
}

-(void) raft_call_become_candidate
{
    raft_become_candidate(raft_server);
}

- (void)raft_start:(int)startCandidate
{
    if (self.raft_started)
        return;
    self.raft_started = YES;
    
    // No need to advertise and scan anymore as the game has started
    //[self.peripheralManager stopAdvertising];
    //[self.centralManager stopScan];
    
    // Discover the services of the connected peripherals
    // It is possible that the characteristics won't be discovered yet when this device
    // becomes a candidate. This is fine because it just means the device won't get enough
    // votes to become the master
    for (CBPeripheral* peripheral in [self.connectedPeripherals allKeys]) {
        // Search only for services that match our UUID
        [peripheral discoverServices:@[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]]];
    }

    // set up the raft configuration with yourself as idx 0
    // keep a dictionary mapping UUID of peripheral to idx in nodes
    NSUInteger numConnected = [[self.connectedPeripherals allKeys] count];
    
    // Store the connected peripherals into nodes array
    NSNumber *idx = @1;
    for (CBPeripheral *p in [self.connectedPeripherals allKeys]) {
        [self.PeripheralRaftIdxDict setObject:idx forKey:p];
        [self.PeripheralRaftIdxDict setObject:p forKey:idx];
        idx = @([idx intValue] + 1);
    }
    
    raft_set_configuration(raft_server, (int)numConnected + 1);
    
    // MAKE SURE THIS WORKS
    if (startCandidate) {
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         target:self
                                       selector:@selector(raft_call_become_candidate)
                                       userInfo:nil
                                        repeats:NO];
    }

    // periodically update raft state
    [NSTimer scheduledTimerWithTimeInterval:RAFT_PERIODIC_SEC
                                     target:self
                                   selector:@selector(raft_call_periodic)
                                   userInfo:nil
                                    repeats:YES];
}

CBCharacteristic *getCharacterisitic(int peer, NSString *charUUID, CBPeripheral **retP)
{
    // Get the peripheral with the given index
    CBPeripheral *p = pPeripheralRaftIdxDict[[NSNumber numberWithInt:peer]];
    *retP = p;
    
    // Get the right characteristic
    NSMutableDictionary *characs = pConnectedPeripherals[p];
    if (characs) {
        CBCharacteristic *charac = characs[[CBUUID UUIDWithString:charUUID]];
        return charac;
    }
    return NULL;
}

/* Write to RAFT_FROM_CANDIDATE characterisitic of peer */
int send_requestvote(raft_server_t* raft, int peer, msg_requestvote_t* msg)
{
    CBPeripheral *p;
    CBCharacteristic *charac = getCharacterisitic(peer, RAFT_FROM_CANDIDATE_CHAR_UUID, &p);
    if (charac) {
        unsigned char uuid[16];
        [[[UIDevice currentDevice] identifierForVendor] getUUIDBytes:uuid];
        memcpy(&msg->uuid, uuid, 16);
        NSLog(@"SENDING: %@", [[[NSUUID alloc] initWithUUIDBytes:msg->uuid] UUIDString]);
        NSData *dataToWrite = [NSData dataWithBytes:msg length:sizeof(msg_requestvote_t)];
        [p writeValue:dataToWrite forCharacteristic:charac type:CBCharacteristicWriteWithoutResponse];
        return 1;
    }
    return 0;
}

/* Write to own RAFT_TO_CANDIDATE characteristic */
int send_requestvote_response(raft_server_t* raft, int peer, msg_requestvote_response_t* msg)
{
    if(msg->vote_granted == 0) return 1;
    
    NSLog(@"VOTING FOR %@", [[[NSUUID alloc] initWithUUIDBytes:msg->uuid] UUIDString]);
    NSData *dataToWrite = [NSData dataWithBytes:msg length:sizeof(msg_requestvote_response_t)];
    [pPeripheralManager updateValue:dataToWrite forCharacteristic:pToCandidateCharacteristic onSubscribedCentrals:nil];
    return 1;
}

/* Write to RAFT_FROM_CENTRAL characterisitic of peer */
// TODO! make sure all these structs are not too big. How much room do we have?
// maximumUpdateValueLength
int send_appendentries(raft_server_t* raft, int peer, msg_appendentries_t* msg)
{
    CBPeripheral *p;
    CBCharacteristic *charac = getCharacterisitic(peer, RAFT_FROM_CENTRAL_CHAR_UUID, &p);
    if (charac) {
        NSData *dataToWrite = [NSData dataWithBytes:msg length:sizeof(msg_appendentries_t)];
        [p writeValue:dataToWrite forCharacteristic:charac type:CBCharacteristicWriteWithoutResponse];
        return 1;
    }
    return 0;
}

/* Write to own RAFT_TO_CENTRAL characteristic */
int send_appendentries_response(raft_server_t* raft, int peer, msg_appendentries_response_t* msg)
{
    NSData *dataToWrite = [NSData dataWithBytes:msg length:sizeof(msg_appendentries_response_t)];
    [pPeripheralManager updateValue:dataToWrite forCharacteristic:pToCentralCharacteristic onSubscribedCentrals:nil];
    return 1;
}

int applylog(raft_server_t* raft, void *udata, msg_entry_t entry)
{
    CGPoint p;
    p.x = entry.data[0];
    p.y = entry.data[1];
    NSLog(@"actually drawing the point: %f, %f", p.x, p.y);
    [pScene drawTouch:p];
    return 1;
}

int startscan() {
    //[pCentralManager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]]
     //                                           options:@{ CBCentralManagerScanOptionAllowDuplicatesKey : @YES }];
    return 1;
}

int stopscan() {
    //[pCentralManager stopScan];
    return 1;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Configure the view.
    SKView * skView = (SKView *)self.view;
    skView.showsFPS = NO;
    skView.showsNodeCount = YES;
    /* Sprite Kit applies additional optimizations to improve rendering performance */
    skView.ignoresSiblingOrder = YES;
    
    // Create and configure the scene.
    self.scene = [GameScene unarchiveFromFile:@"GameScene"];
    self.scene.scaleMode = SKSceneScaleModeAspectFill;
    pScene = self.scene;
    
    // create a new raft server
    raft_server = raft_new(0);
    
    raft_cbs_t funcs = {
        .send_requestvote = send_requestvote ,
        .send_requestvote_response = send_requestvote_response ,
        .send_appendentries = send_appendentries ,
        .send_appendentries_response = send_appendentries_response ,
        .applylog = applylog ,
        .startscan = startscan ,
        .stopscan = stopscan
    };
    
    /* don't think we need the passed in udata to this function */
    raft_set_callbacks(raft_server, &funcs);
    
    // TODO init the RaftBLE instance

    // Present the scene.
    [skView presentScene:self.scene];
}

- (void)viewWillDisappear:(BOOL)animated
{
    // Don't keep it going while we're not showing.
    /*[self.peripheralManager stopAdvertising];
    [self.centralManager stopScan];
    NSLog(@"Scanning stopped"); */
    
    [super viewWillDisappear:animated];
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        return UIInterfaceOrientationMaskAllButUpsideDown;
    } else {
        return UIInterfaceOrientationMaskAll;
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Release any cached data, images, etc that aren't in use.
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}


@end
