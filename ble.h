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
#ifndef BLE_H_
#define BLE_H_

// Integer error codes that can be returned from most of these ble API functions.
#define BLE_ERROR_NONE              0 // Success
#define BLE_ERROR_CONNECT           1 // Connection to device failed.
#define BLE_ERROR_PARAM             2 // Invalid parameter passed to API.
#define BLE_ERROR_MEMORY            3 // Out of memory.
#define BLE_ERROR_NOT_CONNECTED     4 // No device connected.
#define BLE_ERROR_NO_REQUEST        5 // Not waiting for a response from a request.
#define BLE_ERROR_TIMEOUT           6 // Timed out waiting for response.
#define BLE_ERROR_EMPTY             7 // The queue was empty.
#define BLE_ERROR_BAD_RESPONSE      8 // Unexpected response from device.
#define BLE_ERROR_WRITE_FAILED      9 // Write failed.

// Initialize the BLE transport.
// * It should be called from a console application's main().
// * It initializes the low level transport layer and starts a separate thread to run the developer's code.  The
//   developer provides this code in their implementation of the workerMain() function.
void bleInitAndRun(void);

// This is the API that the developer must provide to run their code.  It will be run on a separate thread while
// the main thread is used for handling OS X events via a NSApplicationDelegate.
void workerMain(void);

int bleConnect(const char* pName);
int bleDisconnect();
int bleSetToCurrentTime();
int bleSetToCelsius();
int bleSetToFahrenheit();

#endif // BLE_H_
