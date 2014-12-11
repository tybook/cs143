//
//  RaftBLE.m
//  CS143
//
//  Created by Ty Book on 12/10/14.
//  Copyright (c) 2014 Peter Bang, Ty Book, Todd Lubin. All rights reserved.
//

#import "RaftBLE.h"
#import "raft.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <UIKit/UIKit.h>


@interface RaftBLE () <CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate>

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
@property (strong, nonatomic) CBMutableCharacteristic   *toCandidateCharacteristic;
@property (strong, nonatomic) CBMutableCharacteristic   *fromCandidateCharacteristic;
/* Client proposals of data */
@property (strong, nonatomic) CBMutableCharacteristic   *proposeCharacteristic;
/* New device is waiting to join */
@property (strong, nonatomic) CBMutableCharacteristic   *joinCharacteristic;

/* Two way dictionary from UUID to RaftIdx and from RaftIdx to UUID */
@property (strong, nonatomic)  NSMutableDictionary *PeripheralRaftIdxDict;

/* Indices inside of raft nodes that have disconnected and can be reused */
@property (strong, nonatomic) NSMutableArray *freeIndices;

/* Whether or not the raft server has started at this node */
@property (assign, nonatomic)  BOOL raft_started;

@end

raft_server_t *raft_server;

/* I need global references to connectedPeripherals and PeripheralRaftIdxDict because they are
 used in the c callback functions passed to raft. I want to use properties so that it can
 use ARC for me, so I just keep global references to the instance variables...ew */
NSMutableDictionary *pConnectedPeripherals;
NSMutableDictionary *pPeripheralRaftIdxDict;
CBPeripheralManager *pPeripheralManager;
CBMutableCharacteristic *pToCandidateCharacteristic;
CBMutableCharacteristic *pToCentralCharacteristic;
CBCentralManager      *pCentralManager;
id<RaftBLEDelegate>   pDelegate;


#define RAFT_SERVICE_UUID                      @"698C6448-C9A4-4CAC-A30A-D33F3AF25330"
#define RAFT_TO_CENTRAL_CHAR_UUID              @"F6ACB6F5-04C5-441C-A5AF-12129B550E58"
#define RAFT_FROM_CENTRAL_CHAR_UUID            @"02E6CA47-2D9E-4A09-8117-34D1545715DA"
#define RAFT_TO_CANDIDATE_CHAR_UUID            @"C1224A79-4715-4FFB-B43F-EA2B425EDD98"
#define RAFT_FROM_CANDIDATE_CHAR_UUID          @"85B3A6E5-42AF-4F8F-AECD-50E60A65A521"
#define RAFT_PROPOSE_CHAR_UUID                 @"6A401949-869B-4DAF-9E75-2FFEF411EDEE"
#define RAFT_JOIN_CHAR_UUID                    @"2189B982-FD8E-46E1-9BB5-A35996E1FB3D"

#define RAFT_PERIODIC_SEC                     0.01

@implementation RaftBLE

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

int applylog(raft_server_t* raft, msg_entry_t entry)
{
    [pDelegate applyLog:entry.data];
    return 1;
}

#pragma mark - Lifecycle
- (id) initWithDelegate:(id<RaftBLEDelegate>)delegate
{
    if (self = [super init]) {
        // create a new raft server
        raft_server = raft_new(0);
        
        raft_cbs_t funcs = {
            .send_requestvote = send_requestvote ,
            .send_requestvote_response = send_requestvote_response ,
            .send_appendentries = send_appendentries ,
            .send_appendentries_response = send_appendentries_response ,
            .applylog = applylog ,
        };
        
        /* don't think we need the passed in udata to this function */
        raft_set_callbacks(raft_server, &funcs);
        
        
        self.discoveredPeripherals = [[NSMutableArray alloc] init];
        self.connectedPeripherals = [[NSMutableDictionary alloc] init];
        self.PeripheralRaftIdxDict = [[NSMutableDictionary alloc]init];
        pConnectedPeripherals = self.connectedPeripherals;
        pPeripheralRaftIdxDict = self.PeripheralRaftIdxDict;
        
        self.freeIndices = [[NSMutableArray alloc]init];
        
        // Start up the CBPeripheralManager
        self.peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:nil];
        pPeripheralManager = self.peripheralManager;
        
        
        // Start up the CBCentralManager
        //dispatch_queue_t centralQueue = dispatch_queue_create("centralQueue", DISPATCH_QUEUE_SERIAL);
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        pCentralManager = self.centralManager;
        
        self.delegate = delegate;
        pDelegate = self.delegate;
    }
    
    return self;
}

#pragma mark - Raft function
-(void)proposeLog:(unsigned char*)data length:(int)len
{
    msg_entry_t msg;
    memcpy(msg.data, data, len);
        
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


#pragma mark - Peripheral Methods

/** Required protocol method.  We only care about when the peripheralManager
 * is started up */
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
    pToCentralCharacteristic = self.toCentralCharacteristic;
    
    self.toCandidateCharacteristic = [[CBMutableCharacteristic alloc]
                                      initWithType:[CBUUID UUIDWithString:RAFT_TO_CANDIDATE_CHAR_UUID]
                                      properties:CBCharacteristicPropertyNotify|CBCharacteristicPropertyRead
                                      value:nil
                                      permissions:CBAttributePermissionsReadable];
    pToCandidateCharacteristic = self.toCandidateCharacteristic;
    
    self.proposeCharacteristic = [[CBMutableCharacteristic alloc]
                                  initWithType:[CBUUID UUIDWithString:RAFT_PROPOSE_CHAR_UUID]
                                  properties:CBCharacteristicPropertyNotify|CBCharacteristicPropertyRead
                                  value:nil
                                  permissions:CBAttributePermissionsReadable];
    
    self.joinCharacteristic = [[CBMutableCharacteristic alloc]
                               initWithType:[CBUUID UUIDWithString:RAFT_JOIN_CHAR_UUID]
                               properties:CBCharacteristicPropertyNotify|CBCharacteristicPropertyRead
                               value:nil
                               permissions:CBAttributePermissionsReadable];
    
    self.fromCentralCharacteristic = [[CBMutableCharacteristic alloc]
                                      initWithType:[CBUUID UUIDWithString:RAFT_FROM_CENTRAL_CHAR_UUID]
                                      properties:CBCharacteristicPropertyWriteWithoutResponse
                                      value:nil
                                      permissions:CBAttributePermissionsWriteable];
    
    self.fromCandidateCharacteristic = [[CBMutableCharacteristic alloc]
                                        initWithType:[CBUUID UUIDWithString:RAFT_FROM_CANDIDATE_CHAR_UUID]
                                        properties:CBCharacteristicPropertyWriteWithoutResponse
                                        value:nil
                                        permissions:CBAttributePermissionsWriteable];
    
    // Then the service
    CBMutableService *transferService = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:RAFT_SERVICE_UUID]
                                                                       primary:YES];
    
    // Add the characteristic to the service
    transferService.characteristics = @[self.toCentralCharacteristic, self.fromCentralCharacteristic,
                                        self.toCandidateCharacteristic, self.fromCandidateCharacteristic,
                                        self.proposeCharacteristic, self.joinCharacteristic];
    
    // And add it to the peripheral manager
    [self.peripheralManager addService:transferService];
    
    // All we advertise is our service's UUID
    [self.peripheralManager startAdvertising:@{ CBAdvertisementDataServiceUUIDsKey :
                                                    @[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]] }];
    NSLog(@"Advertising started");
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveWriteRequests:(NSArray *)requests
{
    // If this is the first request, and there are connected device, start up the raft server
    if (!self.raft_started && [self.connectedPeripherals count] > 0) {
        [self.delegate gameStarted];
        [self raft_start:0];
    }
    
    for(CBATTRequest *request in requests) {
        NSData* request_data = request.value;
        CBCharacteristic* charac = request.characteristic;
        
        if([charac.UUID isEqual: [CBUUID UUIDWithString: RAFT_FROM_CANDIDATE_CHAR_UUID]])
        {
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
        else if ([charac.UUID isEqual:[CBUUID UUIDWithString:RAFT_FROM_CENTRAL_CHAR_UUID]])
        {
            int node = -1;
            NSString *uuid = [[request.central identifier] UUIDString];
            for (CBPeripheral *p in self.connectedPeripherals) {
                if ([uuid isEqualToString:[[p identifier] UUIDString]]) {
                    node = [self.PeripheralRaftIdxDict[p] intValue];
                }
            }
            msg_appendentries_t appendEntries;
            if (node != -1) {
                [request_data getBytes:&appendEntries length:sizeof(msg_appendentries_t)];
                raft_recv_appendentries(raft_server, node, &appendEntries);
            }
            
        }
    }
}

-(void)peripheralManager:(CBPeripheralManager *)peripheral central:(CBCentral *)central didSubscribeToCharacteristic:(CBCharacteristic *)characteristic
{
    /*if (self.raft_started) {
     [self.peripheralManager stopAdvertising];
     } */
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

/** Whether a peripheral object is in our list of discovered peripherals.
 */
-(BOOL)isDiscovered:(CBPeripheral*) peripheral
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

/** We've connected to the peripheral, now we need to discover the service and characteristics.
 */
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    NSLog(@"Peripheral %@ Connected", peripheral);
    [self.connectedPeripherals setObject:[[NSMutableDictionary alloc]init] forKey:peripheral];
    
    if (!self.raft_started) {
        [self.delegate numConnectedDevicesChanged:[[self.connectedPeripherals allKeys] count]];
    }
    else {
        // discovered a new device while the game is underway
        if ([self.freeIndices count] == 0) {
            // no room in the game to join
            return;
        }
        
        // tell everyone to start scanning and advertising if we are the leader
        if (raft_is_leader(raft_server)) {
            NSData *junk = [NSData dataWithBytes:NULL length:0];
            [self.peripheralManager updateValue:junk forCharacteristic:self.joinCharacteristic onSubscribedCentrals:nil];
            [self.peripheralManager startAdvertising:@{ CBAdvertisementDataServiceUUIDsKey :
                                                            @[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]] }];
        }
        else {
            //[self.centralManager stopScan];
        }
        
        // add entry for newly connected client to the mapping between raft node ID and the corresponding peripheral
        int newIdx = [self.freeIndices[0] intValue];
        [self.freeIndices removeObjectAtIndex:0];
        
        [self.PeripheralRaftIdxDict setObject:[NSNumber numberWithInt:newIdx] forKey:peripheral];
        [self.PeripheralRaftIdxDict setObject:peripheral forKey:[NSNumber numberWithInt:newIdx]];
        
        [peripheral discoverServices:@[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]]];
    }
    
    // Make sure we get the discovery callbacks
    peripheral.delegate = self;
}

/** The Raft Service was discovered
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

/** The Raft characteristics were discovered.
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
    
    // We loop through the array, just in case.
    for (CBCharacteristic *characteristic in service.characteristics) {
        NSLog(@"Discovered characteristic %@", characteristic);
        [dict setObject:characteristic forKey:characteristic.UUID];
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:RAFT_PROPOSE_CHAR_UUID]] ||
            [characteristic.UUID isEqual:[CBUUID UUIDWithString:RAFT_TO_CANDIDATE_CHAR_UUID]] ||
            [characteristic.UUID isEqual:[CBUUID UUIDWithString:RAFT_TO_CENTRAL_CHAR_UUID]]) {
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
    }
}

/** This callback lets us know more data has arrived via notification on the characteristic
 */
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if (error) {
        NSLog(@"Error discovering characteristics: %@", [error localizedDescription]);
        return;
    }
    
    if([characteristic.UUID isEqual: [CBUUID UUIDWithString: RAFT_TO_CANDIDATE_CHAR_UUID]]) {
        msg_requestvote_response_t voteResponse;
        [characteristic.value getBytes:&voteResponse length:sizeof(msg_requestvote_response_t)];
        NSString *receivedVoteeUUID = [[[NSUUID alloc] initWithUUIDBytes:(unsigned char *)voteResponse.uuid] UUIDString];
        if([receivedVoteeUUID isEqualToString:[[[UIDevice currentDevice] identifierForVendor] UUIDString]]) {
            int node = [self.PeripheralRaftIdxDict[peripheral] intValue];
            raft_recv_requestvote_response(raft_server, node, &voteResponse);
        }
    }
    else if ([characteristic.UUID isEqual: [CBUUID UUIDWithString: RAFT_TO_CENTRAL_CHAR_UUID]]) {
        // We should make sure this is targeted for us. This can be done by checking to see if we are the master
        // This is safe because raft guarantees there can't be more than one master. But we still have the issue
        // with candidate votes that must be addressed
        if (!raft_is_leader(raft_server))
            return;
        msg_appendentries_response_t appendEntriesResponse;
        [characteristic.value getBytes:&appendEntriesResponse length:sizeof(msg_appendentries_response_t)];
        int node = [self.PeripheralRaftIdxDict[peripheral] intValue];
        raft_recv_appendentries_response(raft_server, node, &appendEntriesResponse);
        
    }
    else if ([characteristic.UUID isEqual: [CBUUID UUIDWithString: RAFT_PROPOSE_CHAR_UUID]]) {
        if (!raft_is_leader(raft_server))
            return;
        
        msg_entry_t msg;
        [characteristic.value getBytes:&msg length:sizeof(msg_entry_t)];
        int node = [self.PeripheralRaftIdxDict[peripheral] intValue];
        raft_recv_entry(raft_server, node, &msg);
    }
    else if ([characteristic.UUID isEqual: [CBUUID UUIDWithString: RAFT_JOIN_CHAR_UUID]]) {
        // leader found a new device... start scanning and advertising
        [self.centralManager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]]
                                                    options:@{ CBCentralManagerScanOptionAllowDuplicatesKey : @YES }];
        [self.peripheralManager startAdvertising:@{ CBAdvertisementDataServiceUUIDsKey :
                                                        @[[CBUUID UUIDWithString:RAFT_SERVICE_UUID]] }];
    }
}

/** Once the disconnection happens, we need to clean up our local copy of the peripheral
 */
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    NSLog(@"Peripheral %@ Disconnected", peripheral);
    if (self.raft_started) {
        int idx = [[self.PeripheralRaftIdxDict objectForKey:peripheral] intValue];
        [self.PeripheralRaftIdxDict removeObjectForKey:peripheral];
        [self.PeripheralRaftIdxDict removeObjectForKey:[NSNumber numberWithInt:idx]];
        raft_clear_node(raft_server, idx);
        [self.freeIndices addObject:[NSNumber numberWithInt:idx]];
    }
    [self.connectedPeripherals removeObjectForKey:peripheral];
    [self.delegate numConnectedDevicesChanged:[[self.connectedPeripherals allKeys] count]];
    [self.discoveredPeripherals removeObject:peripheral];
    [self cleanup:peripheral];
}

- (void)peripheral:(CBPeripheral *)peripheral didModifyServices:(NSArray *)invalidatedServices
{
    NSLog(@"Peripheral %@ modified services", peripheral);
    [self.connectedPeripherals removeObjectForKey:peripheral];
    [self.delegate numConnectedDevicesChanged:[[self.connectedPeripherals allKeys] count]];
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
