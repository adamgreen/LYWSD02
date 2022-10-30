/*  Copyright (C) 2021  Adam Green (https://github.com/adamgreen)

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
*/
/* Communicate via BLE with Xiaomi LYWSD02 clock with temperature & humidity sensors to set time.
   It runs a NSApplication on the main thread and runs the developer's code on a worker thread workerMain().  This
   code is to be used with console applications on OS X.
*/
#import <Cocoa/Cocoa.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <pthread.h>
#import <stdint.h>
#import <sys/time.h>
#import "ble.h"


// Forward Declarations.
static void* workerThread(void* pArg);


// The local device name advertised by the BLEMRI device.
#define LYWSD02_DEVICE_NAME @"LYWSD02"

// This is the BLEUART service UUID.
#define LYWSD02_SERVICE "ebe0ccb0-7a0a-4b0c-8a1a-6ff2997da3a6"

// Characteristic used to set the time on the LYWSD02.
#define LYWSD02_TIME_WRITE_CHARACTERISTIC "ebe0ccb7-7a0a-4b0c-8a1a-6ff2997da3a6"

// Characteristic used to set the temperature units on the LYWSD02.
#define LYWSD02_TEMP_UNITS_WRITE_CHARACTERISTIC "ebe0ccbe-7a0a-4b0c-8a1a-6ff2997da3a6"



// This is the delegate where most of the work on the main thread occurs.
@interface BleAppDelegate : NSObject <NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate>
{
    CBCentralManager*   manager;
    CBPeripheral*       peripheral;
    CBCharacteristic*   timeWriteCharacteristic;
    CBCharacteristic*   tempUnitsWriteCharacteristic;

    int                 error;
    int32_t             characteristicsToFind;
    BOOL                autoConnect;
    BOOL                isBlePowerOn;
    BOOL                scanOnBlePowerOn;
    BOOL                writeCompleted;

    pthread_mutex_t     connectMutex;
    pthread_cond_t      connectCondition;
    pthread_mutex_t     writeCompleteMutex;
    pthread_cond_t      writeCompleteCondition;
    pthread_t           thread;
}

- (id) initForApp:(NSApplication*) app;
- (int) error;
- (void) clearPeripheral;
- (void) handleDeviceConnect:(id) deviceName;
- (void) foundCharacteristic;
- (void) signalConnectionError;
- (void) waitForConnectToComplete;
- (void) handleDeviceDisconnect:(id) dummy;
- (void) waitForDisconnectToComplete;
- (void) handleTimeWrite:(id) request;
- (void) handleTempUnitsWrite:(id) request;
- (void) handleQuitRequest:(id) dummy;
- (void) startScan;
- (void) stopScan;
@end



@implementation BleAppDelegate
// Initialize this delegate.
// Create necessary synchronization objects for managing worker thread's access to connection and response state.
// Also adds itself as the delegate to the main NSApplication object.
- (id) initForApp:(NSApplication*) app;
{
    int connectMutexResult = -1;
    int connectConditionResult = -1;
    int writeCompleteMutexResult = -1;
    int writeCompleteConditionResult = -1;

    self = [super init];
    if (!self)
        return nil;

    connectMutexResult = pthread_mutex_init(&connectMutex, NULL);
    if (connectMutexResult)
        goto Error;
    connectConditionResult = pthread_cond_init(&connectCondition, NULL);
    if (connectConditionResult)
        goto Error;
    writeCompleteMutexResult = pthread_mutex_init(&writeCompleteMutex, NULL);
    if (writeCompleteMutexResult)
        goto Error;
    writeCompleteConditionResult = pthread_cond_init(&writeCompleteCondition, NULL);
    if (writeCompleteConditionResult)
        goto Error;

    [app setDelegate:self];
    return self;

Error:
    if (writeCompleteConditionResult == 0)
        pthread_cond_destroy(&writeCompleteCondition);
    if (writeCompleteMutexResult == 0)
        pthread_mutex_destroy(&writeCompleteMutex);
    if (connectConditionResult == 0)
        pthread_cond_destroy(&connectCondition);
    if (connectMutexResult == 0)
        pthread_mutex_destroy(&connectMutex);
    return nil;
}


// Invoked when application finishes launching.
// Initialize the Core Bluetooth manager object and also starts up the worker thread.  This worker thread will end up
// running the code in the developer's workerMain() implementation.
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    pthread_create(&thread, NULL, workerThread, self);
}

// Invoked just before application will shutdown.
- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    // Stop any BLE discovery process that might have been taking place.
    [self stopScan];

    // Disconnect from the device if necessary.
    if(peripheral)
    {
        [manager cancelPeripheralConnection:peripheral];
        [self clearPeripheral];
    }

    // Free up resources here rather than dealloc which doesn't appear to be called during NSApplication shutdown.
    [manager release];
    manager = nil;

    pthread_cond_destroy(&connectCondition);
    pthread_mutex_destroy(&connectMutex);
}

// Request CBCentralManager to stop scanning for BLEUART devices.
- (void) stopScan
{
    [manager stopScan];
}

// Clear BLE peripheral member.
- (void) clearPeripheral
{
    if (!peripheral)
        return;

    pthread_mutex_lock(&connectMutex);
        [peripheral setDelegate:nil];
        [peripheral release];
        peripheral = nil;
    pthread_mutex_unlock(&connectMutex);
    pthread_cond_signal(&connectCondition);
}

// Handle device connection request posted to the main thread by the worker thread.
- (void) handleDeviceConnect:(id) deviceName
{
    error = BLE_ERROR_NONE;
    autoConnect = TRUE;
    characteristicsToFind = 2;
    [self startScan];
}

// Request CBCentralManager to scan for BLEUART devices via the service that it broadcasts.
- (void) startScan
{
    if (!isBlePowerOn)
    {
        // Postpone the scan start until later when BLE power on is detected.
        scanOnBlePowerOn = TRUE;
        return;
    }
    else
    {
        [manager scanForPeripheralsWithServices:nil options:nil];
    }
}

// Invoked when the central discovers BLEUART device while scanning.
- (void) centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)aPeripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI
{
    // UNDONE: NSLog(@"peripheral = %@", aPeripheral);
    // UNDONE: NSLog(@"adv = %@", advertisementData);

    // Ignore any discovered devices which aren't named LYWSD02.
    if (![aPeripheral.name isEqualToString:LYWSD02_DEVICE_NAME])
    {
        return;
    }

    // If the user wants to connect to first discovered device then issue connection request now.
    if (autoConnect)
    {
        // Connect to first device found.
        [self stopScan];
        autoConnect = FALSE;
        peripheral = aPeripheral;
        [peripheral retain];
        [manager connectPeripheral:peripheral options:nil];
    }
}

// Invoked whenever a connection is succesfully created with a BLEUART device.
// Start discovering available BLE services on the device.
- (void) centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)aPeripheral
{
    [aPeripheral setDelegate:self];
    [aPeripheral discoverServices:[NSArray arrayWithObject:[CBUUID UUIDWithString:@LYWSD02_SERVICE]]];
}

// Invoked whenever an existing connection with the peripheral is torn down.
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)aPeripheral error:(NSError *)err
{
    [self clearPeripheral];
}

// Invoked whenever the central manager fails to create a connection with the peripheral.
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)aPeripheral error:(NSError *)err
{
    NSLog(@"didFailToConnectPeripheral");
    NSLog(@"err = %@", err);
    [self clearPeripheral];
    [self signalConnectionError];
}

// Error was encountered while attempting to connect to device.
// Record this error and unblock worker thread which is waiting for the connection to complete.
- (void) signalConnectionError
{
    pthread_mutex_lock(&connectMutex);
        characteristicsToFind = -1;
        error = BLE_ERROR_CONNECT;
    pthread_mutex_unlock(&connectMutex);
    pthread_cond_signal(&connectCondition);
}

// Invoked upon completion of a -[discoverServices:] request.
// Discover available characteristics on interested services.
- (void) peripheral:(CBPeripheral *)aPeripheral didDiscoverServices:(NSError *)error
{
    for (CBService *aService in aPeripheral.services)
    {
        /* LYWSD02 specific services */
        if ([aService.UUID isEqual:[CBUUID UUIDWithString:@LYWSD02_SERVICE]])
        {
            [aPeripheral discoverCharacteristics:nil forService:aService];
        }
    }
}

// Invoked upon completion of a -[discoverCharacteristics:forService:] request.
// Perform appropriate operations on interested characteristics.
- (void) peripheral:(CBPeripheral *)aPeripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    /* BLEUART service. */
    if ([service.UUID isEqual:[CBUUID UUIDWithString:@LYWSD02_SERVICE]])
    {
        for (CBCharacteristic *aChar in service.characteristics)
        {
            /* Remember characteristic to set the time. */
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:@LYWSD02_TIME_WRITE_CHARACTERISTIC]])
            {
                timeWriteCharacteristic = aChar;
                [self foundCharacteristic];
            }
            /* Remember characteristic to set the temperature units. */
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:@LYWSD02_TEMP_UNITS_WRITE_CHARACTERISTIC]])
            {
                tempUnitsWriteCharacteristic = aChar;
                [self foundCharacteristic];
            }
        }
    }
}

// Found one of the two characteristics required for communicating with the BLEUART device.
// The worker thread will be waiting for both of these characteristics to be found so there is code to unblock it.
- (void) foundCharacteristic
{
    pthread_mutex_lock(&connectMutex);
        characteristicsToFind--;
    pthread_mutex_unlock(&connectMutex);
    pthread_cond_signal(&connectCondition);
}

// The worker thread calls this selector to wait for the connection to the device to complete.
- (void) waitForConnectToComplete
{
    pthread_mutex_lock(&connectMutex);
        while (characteristicsToFind > 0)
            pthread_cond_wait(&connectCondition, &connectMutex);
    pthread_mutex_unlock(&connectMutex);
}

// The worker thread calls this selector to determine if the main thread has encountered an error.
- (int) error
{
    return error;
}

// Handle device disconnection request posted to the main thread by the worker thread.
- (void) handleDeviceDisconnect:(id) dummy
{
    error = BLE_ERROR_NONE;

    if(!peripheral)
        return;
    [manager cancelPeripheralConnection:peripheral];
}

// The worker thread calls this selector to wait for the disconnection from the device to complete.
- (void) waitForDisconnectToComplete
{
    pthread_mutex_lock(&connectMutex);
        while (peripheral)
            pthread_cond_wait(&connectCondition, &connectMutex);
    pthread_mutex_unlock(&connectMutex);
}

// Handle write to set the time on the device.
- (void) handleTimeWrite:(id) object
{
    if (!peripheral || !timeWriteCharacteristic)
    {
        // Don't have a successful connection so error out.
        error = BLE_ERROR_NOT_CONNECTED;
        return;
    }
    error = BLE_ERROR_NONE;
    writeCompleted = FALSE;

    // Send request to BLEUART via Core Bluetooth.
    NSData* cmdData = (NSData*)object;
    [peripheral writeValue:cmdData forCharacteristic:timeWriteCharacteristic type:CBCharacteristicWriteWithResponse];
}

// Handle write to set the temperature units (C or F) on the device.
- (void) handleTempUnitsWrite:(id) object
{
    if (!peripheral || !tempUnitsWriteCharacteristic)
    {
        // Don't have a successful connection so error out.
        error = BLE_ERROR_NOT_CONNECTED;
        return;
    }
    error = BLE_ERROR_NONE;
    writeCompleted = FALSE;

    // Send request to BLEUART via Core Bluetooth.
    NSData* cmdData = (NSData*)object;
    [peripheral writeValue:cmdData forCharacteristic:tempUnitsWriteCharacteristic type:CBCharacteristicWriteWithResponse];
}

// Invoked when the write has completed.
- (void) peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)err
{
    if (err)
    {
        NSLog(@"Failed peripheral:didWriteValueForCharacteritic:error:()");
        NSLog(@"err = %@", err);
        error = BLE_ERROR_WRITE_FAILED;
    }

    pthread_mutex_lock(&writeCompleteMutex);
        writeCompleted = TRUE;
    pthread_mutex_unlock(&writeCompleteMutex);
    pthread_cond_signal(&writeCompleteCondition);
}

// The worker thread calls this selector to wait for the last write to complete.
- (void) waitForWriteToComplete
{
    pthread_mutex_lock(&writeCompleteMutex);
        while (!writeCompleted)
            pthread_cond_wait(&writeCompleteCondition, &writeCompleteMutex);
    pthread_mutex_unlock(&writeCompleteMutex);
}

// Handle application shutdown request posted to the main thread by the worker thread.
- (void) handleQuitRequest:(id) dummy
{
    [NSApp terminate:self];
}

// Invoked whenever the central manager's state is updated.
- (void) centralManagerDidUpdateState:(CBCentralManager *)central
{
    NSString * state = nil;

    // Display an error to user if there is no BLE hardware and then force an exit.
    switch ([manager state])
    {
        case CBManagerStateUnsupported:
            state = @"The platform/hardware doesn't support Bluetooth Low Energy.";
            break;
        case CBManagerStateUnauthorized:
            state = @"The app is not authorized to use Bluetooth Low Energy.";
            break;
        case CBManagerStatePoweredOff:
            isBlePowerOn = FALSE;
            state = @"Bluetooth is currently powered off.";
            break;
        case CBManagerStatePoweredOn:
            isBlePowerOn = TRUE;
            if (scanOnBlePowerOn)
            {
                scanOnBlePowerOn = FALSE;
                [self startScan];
            }
            return;
        case CBManagerStateUnknown:
        default:
            return;
    }

    NSLog(@"Central manager state: %@", state);
    [NSApp terminate:self];
}
@end



// *** Implementation of lower level C APIs that make use of above Objective-C classes. ***
static BleAppDelegate* g_appDelegate;

// Initialize the BLE2UART transport.
void bleInitAndRun(void)
{
    [NSApplication sharedApplication];
    g_appDelegate = [[BleAppDelegate alloc] initForApp:NSApp];
    [NSApp run];
    [g_appDelegate release];
    return;
}

// Worker thread root function.
// Calls developer's workerMain() function and upon return sends the Quit request to the main application thread.
static void* workerThread(void* pArg)
{
    workerMain();
    [g_appDelegate performSelectorOnMainThread:@selector(handleQuitRequest:) withObject:nil waitUntilDone:YES];
    return NULL;
}

int bleConnect(const char* pName)
{
    NSString* nameObject = nil;

    if (pName)
        nameObject = [NSString stringWithUTF8String:pName];
    [g_appDelegate performSelectorOnMainThread:@selector(handleDeviceConnect:) withObject:nameObject waitUntilDone:YES];
    [g_appDelegate waitForConnectToComplete];
    [nameObject release];

    return [g_appDelegate error];
}

int bleDisconnect()
{
    [g_appDelegate performSelectorOnMainThread:@selector(handleDeviceDisconnect:) withObject:nil waitUntilDone:YES];
    [g_appDelegate waitForDisconnectToComplete];
    sleep(1);

    return [g_appDelegate error];
}

int bleSetToCurrentTime()
{
    struct timeval  time;
    struct timezone zone;
    struct tm       local;

    gettimeofday(&time, &zone);
    localtime_r(&time.tv_sec, &local);

    int32_t seconds = time.tv_sec;
    int32_t timeZone = local.tm_gmtoff / (60 * 60);
    uint8_t packetData[5];
    packetData[0] = seconds;
    packetData[1] = seconds>>8;
    packetData[2] = seconds>>16;
    packetData[3] = seconds>>24;
    packetData[4] = timeZone;

    NSData* p = [NSData dataWithBytesNoCopy:(void*)packetData length:sizeof(packetData) freeWhenDone:NO];
    if (!p)
        return BLE_ERROR_MEMORY;

    [g_appDelegate performSelectorOnMainThread:@selector(handleTimeWrite:) withObject:p waitUntilDone:YES];
    [g_appDelegate waitForWriteToComplete];
    [p release];
    return [g_appDelegate error];
}

static int setTemperatureUnits(BOOL celsius)
{
    uint8_t packetData[1];
    packetData[0] = celsius ? 0x00 : 0x01;

    NSData* p = [NSData dataWithBytesNoCopy:(void*)packetData length:sizeof(packetData) freeWhenDone:NO];
    if (!p)
        return BLE_ERROR_MEMORY;

    [g_appDelegate performSelectorOnMainThread:@selector(handleTempUnitsWrite:) withObject:p waitUntilDone:YES];
    [g_appDelegate waitForWriteToComplete];
    [p release];
    return [g_appDelegate error];
}

int bleSetToCelsius()
{
    return setTemperatureUnits(TRUE);
}

int bleSetToFahrenheit()
{
    return setTemperatureUnits(FALSE);
}
