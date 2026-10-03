//
//  ChordLooper.swift
//  AutoHarpExtension
//

import Foundation
import Observation
import QuartzCore

@Observable
@MainActor
final class LoopSlots {
    let slots: [ChordLooper] = (0..<5).map { _ in ChordLooper() }
}

@Observable
@MainActor
final class ChordLooper {
    enum Phase { case empty, armed, recording, playing, stopped, queued }

    struct Event {
        enum Kind {
            case chord(root: Int, quality: Int, on: Bool)
            case strum(Set<Int>)
            case piano(Set<UInt8>)
        }
        let t: TimeInterval
        let kind: Kind
    }

    private(set) var phase = Phase.empty
    private(set) var events: [Event] = []
    private(set) var duration: TimeInterval = 0
    var isReplaying = false
    private var start = (root: 0, quality: 0)
    private var changed = false
    private var t0: TimeInterval = 0

    var isPlaying: Bool { phase == .playing }
    var isRecording: Bool { phase == .recording }

    func arm() {
        events = []
        duration = 0
        changed = false
        isReplaying = false
        phase = .armed
    }

    func clear() {
        events = []
        duration = 0
        changed = false
        isReplaying = false
        phase = .empty
    }

    func close(beat: TimeInterval = 0) {
        var d = max(0.01, CACurrentMediaTime() - t0)
        if beat > 0 {
            let beats = max(1, (d / beat + 0.5 - 1e-9).rounded(.down))
            d = beats * beat
            events = events.filter { $0.t < d }
        }
        duration = d
        phase = .playing
    }

    func resume() {
        guard duration > 0, !events.isEmpty else { return }
        phase = .playing
    }

    func queue() {
        guard duration > 0, !events.isEmpty else { return }
        isReplaying = false
        phase = .queued
    }

    func stopKeepingTake() {
        isReplaying = false
        phase = duration > 0 && !events.isEmpty ? .stopped : .empty
    }

    func noteChord(root: Int, quality: Int, on: Bool) {
        guard !isReplaying else { return }
        switch phase {
        case .armed:
            guard on else { return }
            start = (root, quality)
            t0 = CACurrentMediaTime()
            events = [Event(t: 0, kind: .chord(root: root, quality: quality, on: true))]
            changed = false
            phase = .recording
        case .recording:
            if on && (root != start.root || quality != start.quality) { changed = true }
            events.append(Event(t: CACurrentMediaTime() - t0, kind: .chord(root: root, quality: quality, on: on)))
        default:
            break
        }
    }

    func noteStrum(_ pads: Set<Int>) {
        guard !isReplaying, phase == .recording else { return }
        if case .strum(let last) = events.last?.kind, last == pads { return }
        events.append(Event(t: CACurrentMediaTime() - t0, kind: .strum(pads)))
    }

    func notePiano(_ notes: Set<UInt8>) {
        guard !isReplaying, phase == .recording else { return }
        if case .piano(let last) = events.last?.kind, last == notes { return }
        events.append(Event(t: CACurrentMediaTime() - t0, kind: .piano(notes)))
    }
}
