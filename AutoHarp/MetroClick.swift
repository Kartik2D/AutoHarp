//
//  MetroClick.swift
//  AutoHarp
//
//  A decaying click and a sample countdown. Audio thread only writes samples.
//

import AVFoundation
import Foundation
import os

nonisolated final class MetroClick: @unchecked Sendable {
    private struct Run {
        var on = false
        var bpm: Float = 120
        var volume: Float = 0.35
        var rate: Double = 48_000
        var count = 1
        var env: Float = 0
        var phase: Float = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Run())

    func prepare(rate: Double) {
        state.withLock { $0.rate = rate }
    }

    func set(on: Bool) {
        state.withLock {
            let was = $0.on
            $0.on = on
            if on && !was { $0.count = 1 }
        }
    }

    func set(bpm: Float) {
        state.withLock { $0.bpm = min(240, max(40, bpm)) }
    }

    func set(volume: Float) {
        state.withLock { $0.volume = min(1, max(0, volume)) }
    }

    func secondsToNextBeat() -> TimeInterval {
        state.withLock { Double(max(0, $0.count)) / $0.rate }
    }

    func render(_ frameCount: AVAudioFrameCount, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        state.withLock { run in
            let decay = Float(exp(-1.0 / (0.015 * run.rate)))
            let step = Float(2 * Double.pi * 1000 / run.rate)
            let period = max(1, Int(60.0 / Double(max(40, run.bpm)) * run.rate))
            for i in 0..<Int(frameCount) {
                if run.on {
                    run.count -= 1
                    if run.count <= 0 {
                        run.env = 1
                        run.phase = 0
                        run.count = period
                    }
                }
                run.env *= decay
                let sample = sin(run.phase) * run.env * run.volume
                run.phase += step
                if run.phase > Float.pi * 2 { run.phase -= Float.pi * 2 }
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
}
