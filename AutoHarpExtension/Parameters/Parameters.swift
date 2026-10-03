//
//  Parameters.swift
//  AutoHarpExtension
//
//  Created by Kartik Vinayak on 9/11/26.
//

import Foundation
import AudioToolbox

let AutoHarpExtensionParameterSpecs = ParameterTreeSpec {
    ParameterGroupSpec(identifier: "global", name: "Global") {
        ParameterSpec(
            address: .sendNote,
            identifier: "sendNote",
            name: "Send Note",
            units: .boolean,
            valueRange: 0...1,
            defaultValue: 0
        )
        
        ParameterSpec(
            address: .midiNoteNumber,
            identifier: "midiNoteNumber",
            name: "MIDI Note Number",
            units: .midiNoteNumber,
            valueRange: 0...127,
            defaultValue: 60,
            flags: [.flag_IsWritable] // so that hosts like AUM expose this as automatable
        )

        ParameterSpec(
            address: .chordQuality,
            identifier: "chordQuality",
            name: "Chord Quality",
            units: .indexed,
            valueRange: 0...8,
            defaultValue: 0,
            valueStrings: ["maj", "min", "maj7", "min7", "7", "aug", "dim", "sus2", "sus4"]
        )

        ParameterSpec(
            address: .strumNote,
            identifier: "strumNote",
            name: "Strum Note",
            units: .midiNoteNumber,
            valueRange: 0...127,
            defaultValue: 72,
            flags: [.flag_IsWritable]
        )

        ParameterSpec(
            address: .strumGate,
            identifier: "strumGate",
            name: "Strum Gate",
            units: .boolean,
            valueRange: 0...1,
            defaultValue: 0
        )

        ParameterSpec(
            address: .layout,
            identifier: "layout",
            name: "Layout",
            units: .indexed,
            valueRange: 0...1,
            defaultValue: 0,
            flags: [.flag_IsWritable, .flag_IsReadable],
            valueStrings: ["Grid", "Circle of Fifths"]
        )

        ParameterSpec(
            address: .coloring,
            identifier: "coloring",
            name: "Coloring",
            units: .indexed,
            valueRange: 0...1,
            defaultValue: 0,
            flags: [.flag_IsWritable, .flag_IsReadable],
            valueStrings: ["Chromatic", "Fifths"]
        )
    }

    ParameterGroupSpec(identifier: "metro", name: "Metronome") {
        ParameterSpec(
            address: .metroOn,
            identifier: "metroOn",
            name: "Metronome",
            units: .boolean,
            valueRange: 0...1,
            defaultValue: 0
        )
        ParameterSpec(
            address: .metroBPM,
            identifier: "metroBPM",
            name: "Tempo",
            units: .generic,
            valueRange: 40...240,
            defaultValue: 120,
            unitName: "BPM",
            flags: [.flag_IsWritable, .flag_IsReadable]
        )
        ParameterSpec(
            address: .metroWave,
            identifier: "metroWave",
            name: "Waveform",
            units: .indexed,
            valueRange: 0...3,
            defaultValue: 3,
            valueStrings: ["Sine", "Triangle", "Saw", "Square"]
        )
        ParameterSpec(
            address: .metroAttack,
            identifier: "metroAttack",
            name: "Attack",
            units: .milliseconds,
            valueRange: 1...2000,
            defaultValue: 1
        )
        ParameterSpec(
            address: .metroRelease,
            identifier: "metroRelease",
            name: "Release",
            units: .milliseconds,
            valueRange: 10...4000,
            defaultValue: 40
        )
        ParameterSpec(
            address: .metroSustain,
            identifier: "metroSustain",
            name: "Sustain",
            units: .generic,
            valueRange: 0...1,
            defaultValue: 0
        )
        ParameterSpec(
            address: .metroVolume,
            identifier: "metroVolume",
            name: "Volume",
            units: .generic,
            valueRange: 0...1,
            defaultValue: 0.35
        )
        ParameterSpec(
            address: .metroSync,
            identifier: "metroSync",
            name: "Snap to Beat",
            units: .boolean,
            valueRange: 0...1,
            defaultValue: 1
        )
    }

    ParameterGroupSpec(identifier: "drone", name: "Drone") {
        ParameterSpec(
            address: .droneWave,
            identifier: "droneWave",
            name: "Waveform",
            units: .indexed,
            valueRange: 0...3,
            defaultValue: 0,
            valueStrings: ["Sine", "Triangle", "Saw", "Square"]
        )
        ParameterSpec(
            address: .droneAttack,
            identifier: "droneAttack",
            name: "Attack",
            units: .milliseconds,
            valueRange: 1...2000,
            defaultValue: 5
        )
        ParameterSpec(
            address: .droneRelease,
            identifier: "droneRelease",
            name: "Release",
            units: .milliseconds,
            valueRange: 10...4000,
            defaultValue: 150
        )
        ParameterSpec(
            address: .droneSustain,
            identifier: "droneSustain",
            name: "Sustain",
            units: .generic,
            valueRange: 0...1,
            defaultValue: 1
        )
        ParameterSpec(
            address: .droneVolume,
            identifier: "droneVolume",
            name: "Volume",
            units: .generic,
            valueRange: 0...1,
            defaultValue: 0.3
        )
    }

    ParameterGroupSpec(identifier: "strum", name: "Strum") {
        ParameterSpec(
            address: .strumWave,
            identifier: "strumWave",
            name: "Waveform",
            units: .indexed,
            valueRange: 0...3,
            defaultValue: 2,
            valueStrings: ["Sine", "Triangle", "Saw", "Square"]
        )
        ParameterSpec(
            address: .strumAttack,
            identifier: "strumAttack",
            name: "Attack",
            units: .milliseconds,
            valueRange: 1...2000,
            defaultValue: 2
        )
        ParameterSpec(
            address: .strumRelease,
            identifier: "strumRelease",
            name: "Release",
            units: .milliseconds,
            valueRange: 10...4000,
            defaultValue: 2500
        )
        ParameterSpec(
            address: .strumSustain,
            identifier: "strumSustain",
            name: "Sustain",
            units: .generic,
            valueRange: 0...1,
            defaultValue: 0
        )
        ParameterSpec(
            address: .strumVolume,
            identifier: "strumVolume",
            name: "Volume",
            units: .generic,
            valueRange: 0...1,
            defaultValue: 0.18
        )
    }
}

extension ParameterSpec {
    init(
        address: AutoHarpExtensionParameterAddress,
        identifier: String,
        name: String,
        units: AudioUnitParameterUnit,
        valueRange: ClosedRange<AUValue>,
        defaultValue: AUValue,
        unitName: String? = nil,
        flags: AudioUnitParameterOptions = [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
        valueStrings: [String]? = nil,
        dependentParameters: [NSNumber]? = nil
    ) {
        self.init(address: address.rawValue,
                  identifier: identifier,
                  name: name,
                  units: units,
                  valueRange: valueRange,
                  defaultValue: defaultValue,
                  unitName: unitName,
                  flags: flags,
                  valueStrings: valueStrings,
                  dependentParameters: dependentParameters)
    }
}
