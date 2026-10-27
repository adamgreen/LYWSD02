/*  Copyright (C) 2019  Adam Green (https://github.com/adamgreen)

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
*/
/* Sets the time and optionally the temperature units on a Xiaomi LYWSD02 device
   via Bluetooth Low Energy.
*/
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "ble.h"


// How long to scan for LYWSD02 devices before setting the time on all of the devices found.
#define SCAN_SECONDS 10



static void displayUsage(void)
{
    printf("\n"
           "Usage: LYWSD02 [--test] [Celsius | C | Fahrenheit | F]\n"
           "Where:\n"
           "  --test sets the time to 12:34 (today) instead of the current local time.\n"
           "  Celsius or C sets temperature display to be in Celsius.\n"
           "  Fahrenheit or F sets temperature display to be in Fahrenheit.\n"
           "\n"
           "  The time of all LYWSD02 devices found within %d seconds of scanning will\n"
           "  always be updated to match the current local time even if temperature\n"
           "  setting is left blank.\n", SCAN_SECONDS);
}



// Command line flags are parsed into this structure.
typedef enum TemperatureUnits
{
    // No temperature units were specified on command line so leave as is.
    NONE,
    // Celsius units should be used.
    CELSIUS,
    // Fahrenheit units should be used.
    FAHRENHEIT
} TemperatureUnits;

typedef struct CommandLineParams
{
    TemperatureUnits tempUnits;
    int              test;
} CommandLineParams;

static CommandLineParams g_params;



static int parseCommandLine(CommandLineParams* pParams, int argc, char** ppArgs);



int main(int argc, char *argv[])
{
    if (0 != parseCommandLine(&g_params, argc, argv))
    {
        displayUsage();
        return 1;
    }

    /*
       Initialize the Core Bluetooth stack on this the main thread and start the worker thread to run the
       code found in workerMain() below.
    */
    bleInitAndRun();
    return 0;
}

static int parseCommandLine(CommandLineParams* pParams, int argc, char** ppArgs)
{
    int result = 0;

    pParams->tempUnits = NONE;
    pParams->test = 0;

    // Skip executable name.
    ppArgs++;
    argc--;
    while (argc && result == 0)
    {
        const char* pArg = *ppArgs;
        if (0 == strcasecmp(pArg, "celsius") || 0 == strcasecmp(pArg, "c"))
        {
            pParams->tempUnits = CELSIUS;
        }
        else if (0 == strcasecmp(pArg, "fahrenheit") || 0 == strcasecmp(pArg, "f"))
        {
            pParams->tempUnits = FAHRENHEIT;
        }
        else if (0 == strcmp(pArg, "--test"))
        {
            pParams->test = 1;
        }
        else
        {
            fprintf(stderr, "error: '%s' isn't a valid command line flag.\n", pArg);
            return -1;
        }

        ppArgs++;
        argc--;
    }

    return result;
}



static void updateDevice(int index);

// Returns today's 12:34:00 local time, used by the --test option.
static time_t testTime(void)
{
    time_t    now = time(NULL);
    struct tm local;

    localtime_r(&now, &local);
    local.tm_hour = 12;
    local.tm_min = 34;
    local.tm_sec = 0;
    local.tm_isdst = -1;
    return mktime(&local);
}

void workerMain(void)
{
    int count;
    int i;

    printf("Scanning for LYWSD02 devices for %d seconds...\n", SCAN_SECONDS);
    count = bleScan(SCAN_SECONDS);
    if (count == 0)
    {
        fprintf(stderr, "error: No LYWSD02 device found.\n");
        return;
    }
    printf("Found %d LYWSD02 device(s).\n", count);

    for (i = 0 ; i < count ; i++)
    {
        updateDevice(i);
    }
}

static void updateDevice(int index)
{
    int result = -1;
    char deviceId[64];

    if (bleGetDeviceId(index, deviceId, sizeof(deviceId)))
        strcpy(deviceId, "?");

    printf("Attempting to connect to LYWSD02 device %s...\n", deviceId);
    result = bleConnect(index);
    if (result)
    {
        fprintf(stderr, "error: Failed to connect to LYWSD02 device %s.\n", deviceId);
        goto Error;
    }
    printf("LYWSD02 device connected!\n");

    if (g_params.test)
    {
        printf("Setting time to 12:34 (test mode)...\n");
        result = bleSetTime(testTime());
    }
    else
    {
        printf("Updating time...\n");
        result = bleSetToCurrentTime();
    }
    if (result == BLE_ERROR_NOT_CONNECTED)
    {
        printf("BLE connection lost!\n");
    }
    else if (result != BLE_ERROR_NONE)
    {
        printf("BLE transmit returned error: %d\n", result);
    }

    if (g_params.tempUnits == CELSIUS)
    {
        printf("Setting temperature units to Celsius...\n");
        result = bleSetToCelsius();
    }
    else if (g_params.tempUnits == FAHRENHEIT)
    {
        printf("Setting temperature units to Fahrenheit...\n");
        result = bleSetToFahrenheit();
    }
    else
    {
        result = BLE_ERROR_NONE;
    }
    if (result == BLE_ERROR_NOT_CONNECTED)
    {
        printf("BLE connection lost!\n");
    }
    else if (result != BLE_ERROR_NONE)
    {
        printf("BLE transmit returned error: %d\n", result);
    }

Error:
    printf("Disconnecting...\n");
    bleDisconnect();
}
