//
//  Notes.swift
//  AutoHarp
//
//  One note stream for the sampler and MIDI out.
//  Pluck retriggers. A chord change damps notes that are not in the new chord.
//

import AVFoundation
import Foundation

@MainActor
final class Notes {
    static let shared = Notes()

    enum Part: Int {
        case drone = 0
        case strum = 1
    }

    var sampler: [AVAudioUnitSampler?] = [nil, nil]
    var synth: [Oscillator?] = [nil, nil]
    var wave: [Int] = [-1, -1]
    var velocity: [UInt8] = [100, 100]
    private var ringing: [Set<UInt8>] = [[], []]

    func strike(_ note: UInt8, _ part: Part) {
        let ch = part.rawValue
        if ringing[ch].contains(note) { off(note, ch) }
        ringing[ch].insert(note)
        on(note, ch)
    }

    func damp(_ note: UInt8, _ part: Part) {
        let ch = part.rawValue
        guard ringing[ch].contains(note) else { return }
        off(note, ch)
        ringing[ch].remove(note)
    }

    func damp(except keep: Set<UInt8>, _ part: Part) {
        let ch = part.rawValue
        for note in ringing[ch] where !keep.contains(note) { off(note, ch) }
        ringing[ch].formIntersection(keep)
    }

    func hold(_ notes: Set<UInt8>, _ part: Part) {
        let ch = part.rawValue
        for note in ringing[ch] where !notes.contains(note) { off(note, ch) }
        for note in notes where !ringing[ch].contains(note) { on(note, ch) }
        ringing[ch] = notes
    }

    /// Restart the sampler voices already ringing. MIDI stays as it is.
    func replay(_ part: Part) {
        let ch = part.rawValue
        let vel = velocity[ch]
        for note in ringing[ch] {
            sampler[ch]?.stopNote(note, onChannel: 0)
            sampler[ch]?.startNote(note, withVelocity: vel, onChannel: 0)
        }
    }

    private func on(_ note: UInt8, _ ch: Int) {
        let vel = velocity[ch]
        if wave[ch] >= 0 {
            synth[ch]?.on(note, vel)
        } else {
            sampler[ch]?.startNote(note, withVelocity: vel, onChannel: 0)
        }
        MIDIManager.sendNote(on: true, note, velocity: vel, channel: UInt8(ch))
    }

    private func off(_ note: UInt8, _ ch: Int) {
        if wave[ch] >= 0 {
            synth[ch]?.off(note)
        } else {
            sampler[ch]?.stopNote(note, onChannel: 0)
        }
        MIDIManager.sendNote(on: false, note, velocity: 0, channel: UInt8(ch))
    }
}
