//
//  AutoHarpExtensionParameterAddresses.h
//  AutoHarpExtension
//
//  Created by Kartik Vinayak on 9/11/26.
//

#pragma once

#include <AudioToolbox/AUParameters.h>

typedef NS_ENUM(AUParameterAddress, AutoHarpExtensionParameterAddress) {
    sendNote = 0,
    midiNoteNumber = 1,
    chordQuality = 2,
    strumNote = 3,
    strumGate = 4,
    layout = 5,
    coloring = 16,
    metroOn = 17,
    metroBPM = 18,
    metroWave = 19,
    metroAttack = 20,
    metroRelease = 21,
    metroSustain = 22,
    metroVolume = 23,
    metroSync = 24,
    droneWave = 6,
    droneAttack = 7,
    droneRelease = 8,
    droneSustain = 9,
    droneVolume = 10,
    strumWave = 11,
    strumAttack = 12,
    strumRelease = 13,
    strumSustain = 14,
    strumVolume = 15
};
