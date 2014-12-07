//
//  GameViewController.m
//  CS143
//
//  Created by Ty Book on 11/28/14.
//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import "GameViewController.h"
#import "GameScene.h"
#import "raft.h"

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

@property (strong, nonatomic) CBCentralManager      *centralManager;
@property (strong, nonatomic) CBPeripheralManager   *peripheralManager;

/* Peripherals we are connected to */
@property (strong, nonatomic) NSMutableArray   *discoveredPeripherals;
/* connectedPeripherals[p] = Dictionary from Char UUID to characteristic */
@property (strong, nonatomic) NSMutableDictionary *connectedPeripherals;

/* We have an established leader already */
@property (strong, nonatomic) CBMutableCharacteristic   *toCentralCharacteristic;
@property (strong, nonatomic) CBMutableCharacteristic   *fromCentralCharacteristic;
/* Leader election */
@property (strong, nonatomic) CBMutableCharacteristic   *toLeaderCharacteristic;
@property (strong, nonatomic) CBMutableCharacteristic   *fromLeaderCharacteristic;
/* Client proposals of data */
@property (strong, nonatomic) CBMutableCharacteristic   *proposeCharacteristic;

/* Two way dictionary from UUID to RaftIdx and from RaftIdx to UUID */
@property (strong, nonatomic)  NSMutableDictionary *PeripheralRaftIdxDict;

/* Whether or not the raft server has started at this node */
@property (assign, nonatomic)  BOOL raft_started;
@end

raft_server_t *raft_server;

/* I need global references to connectedPeripherals and PeripheralRaftIdxDict because they are
 used in the c callback functions passed to raft. I want to use properties so that it can
 use ARC for me, so I just keep global references to the instance variables...ew */
NSMutableDictionary *pConnectedPeripherals;
NSMutableDictionary *pPeripheralRaftIdxDict;



#define RAFT_SERVICE_UUID                      @"698C6448-C9A4-4CAC-A30A-D33F3AF25330"
#define RAFT_TO_CENTRAL_CHAR_UUID              @"F6ACB6F5-04C5-441C-A5AF-12129B550E58"
#define RAFT_FROM_CENTRAL_CHAR_UUID            @"02E6CA47-2D9E-4A09-8117-34D1545715DA"
#define RAFT_TO_CANDIDATE_ELECTION_CHAR_UUID   @"C1224A79-4715-4FFB-B43F-EA2B425EDD98"
#define RAFT_FROM_CANDIDATE_ELECTION_CHAR_UUID @"85B3A6E5-42AF-4F8F-AECD-50E60A65A521"
#define RAFT_PROPOSE_CHAR_UUID                 @"6A401949-869B-4DAF-9E75-2FFEF411EDEE"

#define RAFT_PERIODIC_SEC                   0.01


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

- (void) raft_call_periodic
{
    raft_periodic(raft_server, RAFT_PERIODIC_SEC * 1000);
}

- (void) raft_start
{
    assert(!self.raft_started);
    self.raft_started = YES;
    
    // No need to advertise and scan anymore as the game has started
    [self.peripheralManager stopAdvertising];
    [self.centralManager stopScan];
    
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
    // one for self and one for NULL termination
    // TODO! This is wasteful to keep index 0 empty, don't think we need it...
    raft_node_configuration_t *nodes = malloc((2 + numConnected)*sizeof(raft_node_configuration_t));

    // make sure this first node (self) doesn't look like the end
    raft_node_configuration_t node = {(void*)1};
    nodes[0] = node;

    
    // Store the connected peripherals into nodes array
    NSNumber *idx = @1;
    for (CBPeripheral *p in [self.connectedPeripherals allKeys]) {
        NSUUID *UUID = [p identifier];
        raft_node_configuration_t node = {(void*)CFBridgingRetain(UUID)};
        nodes[[idx intValue]] = node;
        [self.PeripheralRaftIdxDict setObject:idx forKey:p];
        [self.PeripheralRaftIdxDict setObject:p forKey:idx];
        idx = @([idx intValue] + 1);
    }
    
    raft_node_configuration_t nodeEnd = {(void*)0};
    nodes[[idx intValue]] = nodeEnd;

    raft_set_configuration(raft_server, nodes);
    

    // periodically update raft state
    [NSTimer scheduledTimerWithTimeInterval:RAFT_PERIODIC_SEC
                                     target:self
                                   selector:@selector(raft_call_periodic)
                                   userInfo:nil
                                    repeats:YES];
}

int send_requestvote(raft_server_t* raft, void* udata, int peer, msg_requestvote_t* msg)
{
    CBPeripheral *p = pPeripheralRaftIdxDict[[NSNumber numberWithInt:peer]];
    
    // Write the msg to the right characteristic
    CBUUID *characUUID = [CBUUID UUIDWithString:RAFT_FROM_CANDIDATE_ELECTION_CHAR_UUID];
    NSMutableDictionary *characs = pConnectedPeripherals[p];
    if (characs) {
        CBCharacteristic *charac = characs[characUUID];
        if (charac) {
            NSData *dataToWrite = [NSData dataWithBytes:msg length:sizeof(msg_requestvote_t)];
            NSLog(@"Writing value for characteristic %@", charac);
            [p writeValue:dataToWrite forCharacteristic:charac type:CBCharacteristicWriteWithoutResponse];
            return 1;
        }
    }
    return 0;
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
    
    // create a new raft server
    raft_server = raft_new(0);
    NSUUID *ownUUID = [[UIDevice currentDevice] identifierForVendor];
    NSLog(@"UUID: %@", [ownUUID UUIDString]);
    
    raft_cbs_t funcs = {
        .send_requestvote = send_requestvote
    };
    
    /* don't think we need the passed in udata to this function */
    raft_set_callbacks(raft_server, &funcs, (void*) 0);
    
    
    self.discoveredPeripherals = [[NSMutableArray alloc] init];
    self.connectedPeripherals = [[NSMutableDictionary alloc] init];
    self.PeripheralRaftIdxDict = [[NSMutableDictionary alloc]init];
    pConnectedPeripherals = self.connectedPeripherals;
    pPeripheralRaftIdxDict = self.PeripheralRaftIdxDict;
    
    // Start up the CBPeripheralManager
    self.peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:nil];
    
    // Start up the CBCentralManager
    //dispatch_queue_t centralQueue = dispatch_queue_create("centralQueue", DISPATCH_QUEUE_SERIAL);
    self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    

    // Present the scene.
    [skView presentScene:self.scene];
}

- (void)viewWillDisappear:(BOOL)animated
{
    // Don't keep it going while we're not showing.
    [self.peripheralManager stopAdvertising];
    [self.centralManager stopScan];
    NSLog(@"Scanning stopped");
    
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

#pragma mark - Peripheral Methods

/** Client app proposing data to central (max of 12 bytes of data)
 */
- (void)proposeData:(NSData *)data
{
    // if we are the master ...
    
    // otherwise
    [self.peripheralManager updateValue:data forCharacteristic:self.proposeCharacteristic onSubscribedCentrals:nil];
}

/** Required protocol method.  A full app should take care of all the possible states,
 *  but we're just waiting to know when the CBPeripheralManager is ready
 */
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral
{
    // Opt out from any other state
    if (peripheral.state != CBPeripheralManagerStatePoweredOn) {
        return;
    }
    
    
    // Set up the characteristics
    self.toCentralCharacteristic = [[CBMutableCharacteristic alloc]
                                    initWithType:[CBUUID UUIDWithString:RAFT_TO_CENTRAL_CHAR_UUID]
                                    properties:CBCharacteristicPropertyNotify|CBCharacteristicPropertyRead
                                    value:nil
                                    permissions:CBAttributePermissionsReadable];
    
    self.toLeaderCharacteristic = [[CBMutableCharacteristic alloc]
                                   initWithType:[CBUUID UUIDWithString:RAFT_TO_CANDIDATE_ELECTION_CHAR_UUID]
                                   properties:CBCharacteristicPropertyNotify|CBCharacteristicPropertyRead
                                   value:nil
                                   permissions:CBAttributePermissionsReadable];
    
    self.proposeCharacteristic = [[CBMutableCharacteristic alloc]
                                  initWithType:[CBUUID UUIDWithString:RAFT_PROPOSE_CHAR_UUID]
                                  properties:CBCharacteristicPropertyNotify|CBCharacteristicPropertyRead
                                  value:nil
                                  permissions:CBAttributePermissionsReadable];
    
    self.fromCentralCharacteristic = [[CBMutableCharacteristic alloc]
                                      initWithType:[CBUUID UUIDWithString:RAFT_FROM_CENTRAL_CHAR_UUID]
                                      properties:CBCharacteristicPropertyWriteWithoutResponse
                                      value:nil
                                      permissions:CBAttributePermissionsWriteable];
    
    self.fromLeaderCharacteristic = [[CBMutableCharacteristic alloc]
                                     initWithType:[CBUUID UUIDWithString:RAFT_FROM_CANDIDATE_ELECTION_CHAR_UUID]
                                     properties:CBCharacteristicPropertyWriteWithoutResponse
                                     value:nil
                                     permissions:CBAttributePermissionsWriteable];
    
    // Then the service
    CBMutableService *transferService = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:RAFT_SERVICE_UUID]
                                                                       primary:YES];
    
    // Add the characteristic to the service
    transferService.characteristics = @[self.toCentralCharacteristic, self.fromCentralCharacteristic,
                                        self.toLeaderCharacteristic, self.fromLeaderCharacteristic,
                                        self.proposeCharacteristic];
    
    // And add it to the peripheral manager
    [self.peripheralManager addService:transferService];
    
    // All we advertise is our service's UUID
    [self.peripheralManager startAdvertising:@{ CBAdvertisementDataServiceUUIDsKey :
                                                    @[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]] }];
    NSLog(@"Advertising started");
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveWriteRequests:(NSArray *)requests
{
    /* If this is the first request, start up the raft server */
    if (!self.raft_started) {
        [self raft_start];
    }
    
    /* TODO! loop through all the requests, not just the first one */
    CBATTRequest* request = [requests objectAtIndex:0];
    NSData* request_data = request.value;
    CBCharacteristic* charac = request.characteristic;

    if([charac.UUID isEqual: [CBUUID UUIDWithString: RAFT_FROM_CANDIDATE_ELECTION_CHAR_UUID]])
    {
        NSLog(@"Got message from candidate for election");
        
        /* We need to get the node number for the central that made the request.
            We can get a CBCentral but this won't equal the CBPeripheral we store
            in our dictionaries. Unless we make changes, we have to enumerate the dictionary
            and look for a matching UUID */
        int node = -1;
        NSString *uuid = [[request.central identifier] UUIDString];
        for (CBPeripheral *p in self.connectedPeripherals) {
            if ([uuid isEqualToString:[[p identifier] UUIDString]]) {
                node = [self.PeripheralRaftIdxDict[p] intValue];
            }
        }
        msg_requestvote_t requestvote;
        if (node != -1) {
            [request_data getBytes:&requestvote length:sizeof(msg_requestvote_t)];
            raft_recv_requestvote(raft_server, node, &requestvote);
        }
    }
}

#pragma mark - Central Methods

/** centralManagerDidUpdateState is a required protocol method.
 *  Usually, you'd check for other states to make sure the current device supports LE, is powered on, etc.
 *  In this instance, we're just using it to wait for CBCentralManagerStatePoweredOn, which indicates
 *  the Central is ready to be used.
 */
- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    if (central.state != CBCentralManagerStatePoweredOn) {
        return;
    }
    
    // Start scanning
    [self.centralManager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]]
                                                options:@{ CBCentralManagerScanOptionAllowDuplicatesKey : @YES }];
    NSLog(@"Scanning started");
}

-(BOOL) isDiscovered:(CBPeripheral*) peripheral
{
    for (CBPeripheral *p in self.discoveredPeripherals) {
        if ([[[p identifier] UUIDString] isEqualToString:[[peripheral identifier] UUIDString]]) {
            return YES;
        }
    }
    return NO;
}

/** This callback comes whenever a peripheral that is advertising the RAFT_SERVICE_UUID is discovered.
 *  We start the connection process
 */
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI
{
    //NSLog(@"Discovered %@ at %@", peripheral.name, RSSI);
    
    // Ok, it's in range - have we already seen it?
    if (![self isDiscovered:peripheral]) {
        // connect
        NSLog(@"Discovered %@, trying to connect", peripheral);
        [self.discoveredPeripherals addObject:peripheral];
        [self.centralManager connectPeripheral:peripheral options:nil];
    }
}

/** If the connection fails for whatever reason, we need to deal with it.
 */
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    NSLog(@"Failed to connect to %@. (%@)", peripheral, [error localizedDescription]);
    assert([self isDiscovered:peripheral]);
    [self.discoveredPeripherals removeObject:peripheral];
    [self cleanup:peripheral];
}

/** We've connected to the peripheral, now we need to discover the services and characteristics to find the 'transfer' characteristic.
 */
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    NSLog(@"Peripheral %@ Connected", peripheral);
    [self.connectedPeripherals setObject:[[NSMutableDictionary alloc]init] forKey:peripheral];
    [self.scene handleConnected:[[self.connectedPeripherals allKeys] count]];
    
    // Make sure we get the discovery callbacks
    peripheral.delegate = self;
}

/** The Transfer Service was discovered
 */
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    if (error) {
        NSLog(@"Error discovering services: %@", [error localizedDescription]);
        [self cleanup:peripheral];
        return;
    }
    
    // Loop through the newly filled peripheral.services array, just in case there's more than one.
    for (CBService *service in peripheral.services) {
        NSLog(@"Discovered service %@", service);
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

/** The Transfer characteristic was discovered.
 */
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    // Deal with errors (if any)
    if (error) {
        NSLog(@"Error discovering characteristics: %@", [error localizedDescription]);
        [self cleanup:peripheral];
        return;
    }
    NSMutableDictionary *dict = [self.connectedPeripherals objectForKey:peripheral];
    
    // Again, we loop through the array, just in case.
    for (CBCharacteristic *characteristic in service.characteristics) {
        NSLog(@"Discovered characteristic %@", characteristic);
        [dict setObject:characteristic forKey:characteristic.UUID];
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:RAFT_PROPOSE_CHAR_UUID]]) {
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
    }
}

/** This callback lets us know more data has arrived via notification on the characteristic
 */
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    NSLog(@"didUpdateValueForCharacteristic: %@", characteristic);
    if (error) {
        NSLog(@"Error discovering characteristics: %@", [error localizedDescription]);
        return;
    }
    
    // Right now we know that we are just getting coordinates...
    // |_ x coor _ | _ y coor _ | 8 bytes
    
    /*float coors[2];
    [characteristic.value getBytes:coors length:8];
 
    CGPoint point = CGPointMake(coors[0], coors[1]);
    [self.scene drawTouch:point];*/
}

/** Once the disconnection happens, we need to clean up our local copy of the peripheral
 */
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    NSLog(@"Peripheral %@ Disconnected", peripheral);
    [self.connectedPeripherals removeObjectForKey:peripheral];
    [self.scene handleConnected:[[self.connectedPeripherals allKeys] count]];
    [self.discoveredPeripherals removeObject:peripheral];
    [self cleanup:peripheral];
}

- (void)peripheral:(CBPeripheral *)peripheral didModifyServices:(NSArray *)invalidatedServices
{
    NSLog(@"Peripheral %@ modified services", peripheral);
    [self.connectedPeripherals removeObjectForKey:peripheral];
    [self.scene handleConnected:[[self.connectedPeripherals allKeys] count]];
    [self.discoveredPeripherals removeObject:peripheral];
    [self cleanup:peripheral];
}

/** Call this when things either go wrong, or you're done with the connection.
 *  This cancels any subscriptions if there are any, or straight disconnects if not.
 *  (didUpdateNotificationStateForCharacteristic will cancel the connection if a subscription is involved)
 */
- (void)cleanup: (CBPeripheral *)peripheral
{
    // See if we are subscribed to a characteristic on the peripheral
    if (peripheral.services != nil) {
        for (CBService *service in peripheral.services) {
            if (service.characteristics != nil) {
                for (CBCharacteristic *characteristic in service.characteristics) {
                    if (characteristic.isNotifying) {
                        // It is notifying, so unsubscribe
                        [peripheral setNotifyValue:NO forCharacteristic:characteristic];
                    }
                }
            }
        }
    }
    
    // If we've got this far, we're connected, but we're not subscribed, so we just disconnect
    [self.centralManager cancelPeripheralConnection:peripheral];
    
}


@end
