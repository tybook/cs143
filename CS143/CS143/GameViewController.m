//
//  GameViewController.m
//  CS143
//
//  Created by Ty Book on 11/28/14.
//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import "GameViewController.h"
#import "GameScene.h"
#import <CoreBluetooth/CoreBluetooth.h>

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
@property (strong, nonatomic) CBCentralManager      *centralManager;
@property (strong, nonatomic) CBPeripheralManager   *peripheralManager;

/* Peripherals we are connected to */
@property (strong, nonatomic) NSMutableSet *discoveredPeripherals;

/* We have an established leader already */
@property (strong, nonatomic) CBMutableCharacteristic   *toCentralCharacteristic;
@property (strong, nonatomic) CBMutableCharacteristic   *fromCentralCharacteristic;

/* Leader election */
@property (strong, nonatomic) CBMutableCharacteristic   *toLeaderCharacteristic;
@property (strong, nonatomic) CBMutableCharacteristic   *fromLeaderCharacteristic;

/* Client proposals of data */
@property (strong, nonatomic) CBMutableCharacteristic   *proposeCharacteristic;
@end

#define RAFT_SERVICE_UUID                   @"698C6448-C9A4-4CAC-A30A-D33F3AF25330"
#define RAFT_TO_CENTRAL_CHAR_UUID           @"F6ACB6F5-04C5-441C-A5AF-12129B550E58"
#define RAFT_FROM_CENTRAL_CHAR_UUID         @"02E6CA47-2D9E-4A09-8117-34D1545715DA"
#define RAFT_TO_LEADER_ELECTION_CHAR_UUID   @"C1224A79-4715-4FFB-B43F-EA2B425EDD98"
#define RAFT_FROM_LEADER_ELECTION_CHAR_UUID @"85B3A6E5-42AF-4F8F-AECD-50E60A65A521"
#define RAFT_PROPOSE_CHAR_UUID              @"6A401949-869B-4DAF-9E75-2FFEF411EDEE"


@implementation GameViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Configure the view.
    SKView * skView = (SKView *)self.view;
    skView.showsFPS = YES;
    skView.showsNodeCount = YES;
    /* Sprite Kit applies additional optimizations to improve rendering performance */
    skView.ignoresSiblingOrder = YES;
    
    // Create and configure the scene.
    GameScene *scene = [GameScene unarchiveFromFile:@"GameScene"];
    scene.scaleMode = SKSceneScaleModeAspectFill;
    
    self.discoveredPeripherals = [[NSMutableSet alloc] init];
    
    // Start up the CBPeripheralManager
    self.peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:nil];
    
    // Start up the CBCentralManager
    self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    
    
    // delay for a bit
    
    // Present the scene.
    [skView presentScene:scene];
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

/** Required protocol method.  A full app should take care of all the possible states,
 *  but we're just waiting for  to know when the CBPeripheralManager is ready
 */
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral
{
    // Opt out from any other state
    if (peripheral.state != CBPeripheralManagerStatePoweredOn) {
        return;
    }
    
    // We're in CBPeripheralManagerStatePoweredOn state...
    NSLog(@"self.peripheralManager powered on.");
    
    // ... so build our service.
    
    // Set up the characteristics
    self.toCentralCharacteristic = [[CBMutableCharacteristic alloc]
                                    initWithType:[CBUUID UUIDWithString:RAFT_TO_CENTRAL_CHAR_UUID]
                                    properties:CBCharacteristicPropertyNotify|CBCharacteristicPropertyRead
                                    value:nil
                                    permissions:CBAttributePermissionsReadable];
    
    self.toLeaderCharacteristic = [[CBMutableCharacteristic alloc]
                                   initWithType:[CBUUID UUIDWithString:RAFT_TO_LEADER_ELECTION_CHAR_UUID]
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
                                     initWithType:[CBUUID UUIDWithString:RAFT_FROM_LEADER_ELECTION_CHAR_UUID]
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
        // In a real app, you'd deal with all the states correctly
        return;
    }
    
    // The state must be CBCentralManagerStatePoweredOn...
    
    // ... so start scanning
    [self.centralManager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]]
                                                options:@{ CBCentralManagerScanOptionAllowDuplicatesKey : @YES }];
    NSLog(@"Scanning started");
}

/** This callback comes whenever a peripheral that is advertising the RAFT_SERVICE_UUID is discovered.
 *  We start the connection process
 */
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI
{
    NSLog(@"Discovered %@ at %@", peripheral.name, RSSI);
    
    // Ok, it's in range - have we already seen it?
    if (![self.discoveredPeripherals member:peripheral]) {
        
        // Save a local copy of the peripheral, so CoreBluetooth doesn't get rid of it
        [self.discoveredPeripherals addObject:peripheral];
        
        // And connect
        NSLog(@"Connecting to peripheral %@", peripheral);
        [self.centralManager connectPeripheral:peripheral options:nil];
    }
}

/** If the connection fails for whatever reason, we need to deal with it.
 */
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    NSLog(@"Failed to connect to %@. (%@)", peripheral, [error localizedDescription]);
    [self cleanup:peripheral];
}

/** We've connected to the peripheral, now we need to discover the services and characteristics to find the 'transfer' characteristic.
 */
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    NSLog(@"Peripheral %@ Connected", peripheral);
    
    // Clear the data that we may already have
    //    [self.data setLength:0];
    
    // Make sure we get the discovery callbacks
    peripheral.delegate = self;
    
    // Search only for services that match our UUID
    [peripheral discoverServices:@[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]]];
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
    
    // Discover the characteristic we want...
    
    // Loop through the newly filled peripheral.services array, just in case there's more than one.
    for (CBService *service in peripheral.services) {
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
    
    // Again, we loop through the array, just in case.
    for (CBCharacteristic *characteristic in service.characteristics) {
        NSLog(@"Discovered characteristic %@", characteristic);
    }
}

/** This callback lets us know more data has arrived via notification on the characteristic
 */
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    NSLog(@"THIS SHOULD NOT BE CALLED");
    /*    if (error) {
     NSLog(@"Error discovering characteristics: %@", [error localizedDescription]);
     return;
     }
     
     NSString *stringFromData = [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];
     
     // Have we got everything we need?
     if ([stringFromData isEqualToString:@"EOM"]) {
     
     // We have, so show the data,
     [self.textview setText:[[NSString alloc] initWithData:self.data encoding:NSUTF8StringEncoding]];
     
     // Cancel our subscription to the characteristic
     [peripheral setNotifyValue:NO forCharacteristic:characteristic];
     
     // and disconnect from the peripehral
     [self.centralManager cancelPeripheralConnection:peripheral];
     }
     
     // Otherwise, just add the data on to what we already have
     [self.data appendData:characteristic.value];
     
     // Log it
     NSLog(@"Received: %@", stringFromData); */
}

/** Once the disconnection happens, we need to clean up our local copy of the peripheral
 */
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    NSLog(@"Peripheral %@ Disconnected", peripheral);
    [self cleanup:peripheral];
}

/** Call this when things either go wrong, or you're done with the connection.
 *  This cancels any subscriptions if there are any, or straight disconnects if not.
 *  (didUpdateNotificationStateForCharacteristic will cancel the connection if a subscription is involved)
 */
- (void)cleanup: (CBPeripheral *)peripheral
{
    // Don't do anything if we're not connected
    if (!peripheral.isConnected) {
        return;
    }
    
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
    
    // Remove it from self.discoveredPeripherals
    [self.discoveredPeripherals removeObject:peripheral];
}


@end
