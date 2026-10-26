//
//  Oscillator.swift
//  AutoHarp
//
//  The original waves: sine, triangle, saw, square. One voice per held note.
//

import AVFoundation
import Foundation
import os

enum Wave: Int, CaseIterable {
    case sine, triangle, saw, square

    var name: String {
        switch self {
        case .sine: "Sine"
        case .triangle: "Triangle"
        case .saw: "Saw"
        case .square: "Square"
        }
    }
}

nonisolated final class Oscillator: @unchecked Sendable {
    private struct Voice {
        var note: UInt8
        var phase: Float
        var step: Float
        var amp: Float
        var target: Float
    }

    private struct Run {
        var wave = Wave.sine.rawValue
        var level: Float = 0.3
        var rate: Double = 48_000
        /// Time to fall to silence. Zero holds until the note is stopped.
        var release: Float = 0
        var voices: [Voice] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: Run())

    func prepare(rate: Double) {
        state.withLock { $0.rate = rate }
    }

    func set(wave: Wave) {
        state.withLock { $0.wave = wave.rawValue }
    }

    func set(level: Float) {
        state.withLock { $0.level = min(1, max(0, level)) }
    }

    func set(release seconds: Float) {
        state.withLock { $0.release = max(0, seconds) }
    }

    func on(_ note: UInt8, _ velocity: UInt8) {
        state.withLock { run in
            let step = Float(440 * pow(2, (Double(note) - 69) / 12) / run.rate) * 2 * .pi
            if let i = run.voices.firstIndex(where: { $0.note == note }) {
                run.voices[i].target = Float(velocity) / 127
            } else {
                run.voices.append(Voice(note: note, phase: 0, step: step, amp: 0, target: Float(velocity) / 127))
            }
        }
    }

    func off(_ note: UInt8) {
        state.withLock { run in
            if let i = run.voices.firstIndex(where: { $0.note == note }) { run.voices[i].target = 0 }
        }
    }

    func render(_ frameCount: AVAudioFrameCount, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        state.withLock { run in
            let smooth = Float(1 - exp(-1.0 / (0.005 * run.rate)))
            let decay = run.release > 0 ? Float(exp(-6.9 / (Double(run.release) * run.rate))) : 1
            let shape = run.wave
            for i in 0..<Int(frameCount) {
                var mix: Float = 0
                var v = 0
                while v < run.voices.count {
                    if decay < 1 && run.voices[v].target > 0 { run.voices[v].target *= decay }
                    run.voices[v].amp += (run.voices[v].target - run.voices[v].amp) * smooth
                    if run.voices[v].target == 0 && run.voices[v].amp < 0.0005 {
                        run.voices.remove(at: v)
                        continue
                    }
                    mix += wave(run.voices[v].phase, shape) * run.voices[v].amp
                    run.voices[v].phase += run.voices[v].step
                    if run.voices[v].phase > .pi * 2 { run.voices[v].phase -= .pi * 2 }
                    v += 1
                }
                let sample = mix * run.level
                for buf in buffers {
                    guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let channels = Int(buf.mNumberChannels)
                    if channels <= 1 {
                        data[i] = sample
                    } else {
                        for c in 0..<channels { data[i * channels + c] = sample }
                    }
                }
            }
        }
    }

    private func wave(_ phase: Float, _ shape: Int) -> Float {
        switch shape {
        case 1:
            let t = phase / (.pi * 2)
            return t < 0.5 ? 4 * t - 1 : 3 - 4 * t
        case 2:
            return phase / .pi - 1
        case 3:
            return phase < .pi ? 1 : -1
        default:
            return sin(phase)
        }
    }
}
