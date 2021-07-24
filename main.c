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
#include "ble.h"



static void displayUsage(void)
{
    printf("\n"
           "Usage: LYWSD02 [Celcius | C | Fahrenheit | F]\n"
           "Where:\n"
           "  Celcius or C sets temperature display to be in Celcius.\n"
           "  Fahrenheight or F sets temperature display to be in Fahrenheit.\n"
           "\n"
           "  The device's time will always be updated to match the current local time\n"
           "  even if temperature setting is left blank.\n");
}



// Command line flags are parsed into this structure.
typedef enum TemperatureUnits
{
    // No temperature units were specified on command line so leave as is.
    NONE,
    // Celcius units should be used.
    CELCIUS,
    // Fahrenheit units should be used.
    FAHRENHEIT
} TemperatureUnits;

typedef struct CommandLineParams
{
    TemperatureUnits tempUnits;
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

    // Skip executable name.
    ppArgs++;
    argc--;
    while (argc && result == 0)
    {
        const char* pArg = *ppArgs;
        if (0 == strcasecmp(pArg, "celcius") || 0 == strcasecmp(pArg, "c"))
        {
            pParams->tempUnits = CELCIUS;
        }
        else if (0 == strcasecmp(pArg, "fahrenheit") || 0 == strcasecmp(pArg, "f"))
        {
            pParams->tempUnits = FAHRENHEIT;
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



void workerMain(void)
{
    int result = -1;

    printf("Attempting to connect to LYWSD02 device...\n");
    result = bleConnect(NULL);
    if (result)
    {
        fprintf(stderr, "error: Failed to connect to LYWSD02 device.\n");
        goto Error;
    }
    printf("LYWSD02 device connected!\n");

    printf("Updating time...\n");
    result = bleSetToCurrentTime();
    if (result == BLE_ERROR_NOT_CONNECTED)
    {
        printf("BLE connection lost!\n");
    }
    else if (result != BLE_ERROR_NONE)
    {
        printf("BLE transmit returned error: %d\n", result);
    }

    if (g_params.tempUnits == CELCIUS)
    {
        printf("Setting temperature units to Celcius...\n");
        result = bleSetToCelcius();
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
