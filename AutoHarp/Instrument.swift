//
//  Instrument.swift
//  AutoHarp
//
//  Local monitor + MIDI out. No Audio Unit host.
//

import AVFoundation
import CoreMIDI
import Foundation
import UIKit

@Observable
final class Knob {
    var value: Float {
        didSet { if value != oldValue { apply?(value) } }
    }
    let min: Float
    let max: Float
    var apply: ((Float) -> Void)?

    init(_ value: Float, min: Float = 0, max: Float = 1, apply: ((Float) -> Void)? = nil) {
        self.value = value
        self.min = min
        self.max = max
        self.apply = apply
        apply?(value)
    }
}

final class DSP: @unchecked Sendable {
    var kernel = AutoHarpExtensionDSPKernel()
    var muted = false

    func set(_ address: AutoHarpExtensionParameterAddress, _ value: Float) {
        kernel.setParameter(address.rawValue, value)
    }

    func render(_ sampleTime: Float64, _ frames: AVAudioFrameCount, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        kernel.process(AUEventSampleTime(sampleTime), frames, abl, 0)
        guard muted else { return }
        for buf in UnsafeMutableAudioBufferListPointer(abl) {
            if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) }
        }
    }
}

@Observable
@MainActor
final class Instrument {
    let dsp: DSP
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    let noteParam: Knob
    let gateParam: Knob
    let qualityParam: Knob
    let layoutParam: Knob
    let coloringParam: Knob
    let metroOnParam: Knob
    let metroBPMParam: Knob
    let metroSyncParam: Knob

    let droneWave: Knob
    let droneAttack: Knob
    let droneRelease: Knob
    let droneSustain: Knob
    let droneVolume: Knob
    let strumWave: Knob
    let strumAttack: Knob
    let strumRelease: Knob
    let strumSustain: Knob
    let strumVolume: Knob
    let metroWave: Knob
    let metroAttack: Knob
    let metroRelease: Knob
    let metroSustain: Knob
    let metroVolume: Knob

    var droneEnabled = UserDefaults.standard.object(forKey: "AutoHarp.droneEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(droneEnabled, forKey: "AutoHarp.droneEnabled")
            dsp.kernel.setDroneEnabled(droneEnabled)
        }
    }

    var splitMIDI = UserDefaults.standard.bool(forKey: "AutoHarp.splitMIDI") {
        didSet {
            UserDefaults.standard.set(splitMIDI, forKey: "AutoHarp.splitMIDI")
            dsp.kernel.setSplitMIDI(splitMIDI)
        }
    }

    var pianoEnabled = UserDefaults.standard.bool(forKey: "AutoHarp.pianoEnabled") {
        didSet { UserDefaults.standard.set(pianoEnabled, forKey: "AutoHarp.pianoEnabled") }
    }

    private var themeStorage = HarpTheme(rawValue: UserDefaults.standard.integer(forKey: "AutoHarp.theme")) ?? .classic
    var theme: HarpTheme {
        get { themeStorage }
        set {
            guard newValue != themeStorage else { return }
            themeStorage = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "AutoHarp.theme")
        }
    }

    var soundEnabled = true {
        didSet { dsp.muted = !soundEnabled }
    }

    var layout = min(1, UserDefaults.standard.integer(forKey: "AutoHarp.chordLayout")) {
        didSet {
            UserDefaults.standard.set(layout, forKey: "AutoHarp.chordLayout")
            layoutParam.value = Float(layout)
            coloringParam.value = Float(coloring)
        }
    }

    private var gridColoring = UserDefaults.standard.integer(forKey: "AutoHarp.chordColoring")
    private var fifthsColoring = UserDefaults.standard.object(forKey: "AutoHarp.fifthsColoring") as? Int ?? 1

    var coloring: Int {
        get { layout == 0 ? gridColoring : fifthsColoring }
        set {
            if layout == 0 {
                gridColoring = newValue
                UserDefaults.standard.set(newValue, forKey: "AutoHarp.chordColoring")
            } else {
                fifthsColoring = newValue
                UserDefaults.standard.set(newValue, forKey: "AutoHarp.fifthsColoring")
            }
            coloringParam.value = Float(newValue)
        }
    }

    var metroEnabled = false {
        didSet { metroOnParam.value = metroEnabled ? 1 : 0 }
    }

    var metroBPM: Float {
        get { metroBPMParam.value }
        set { metroBPMParam.value = min(240, max(40, newValue)) }
    }

    var metroSync: Bool {
        get { metroSyncParam.value >= 0.5 }
        set { metroSyncParam.value = newValue ? 1 : 0 }
    }

    private var tempoTaps: [TimeInterval] = []
    private var armed = false
    private var inForeground = true
    private var midiFlush: DispatchSourceTimer?

    init() {
        let core = DSP()
        dsp = core
        func bind(_ address: AutoHarpExtensionParameterAddress, _ value: Float, min: Float = 0, max: Float = 1) -> Knob {
            Knob(value, min: min, max: max) { core.set(address, $0) }
        }

        noteParam = bind(.midiNoteNumber, 60, min: 0, max: 127)
        gateParam = bind(.sendNote, 0)
        qualityParam = bind(.chordQuality, 0, min: 0, max: 8)
        layoutParam = bind(.layout, Float(min(1, UserDefaults.standard.integer(forKey: "AutoHarp.chordLayout"))))
        coloringParam = bind(.coloring, Float(UserDefaults.standard.integer(forKey: "AutoHarp.chordLayout") == 0
            ? UserDefaults.standard.integer(forKey: "AutoHarp.chordColoring")
            : (UserDefaults.standard.object(forKey: "AutoHarp.fifthsColoring") as? Int ?? 1)))
        metroOnParam = bind(.metroOn, 0)
        let storedBPM = (UserDefaults.standard.object(forKey: "AutoHarp.metroBPM") as? Float) ?? 120
        metroBPMParam = Knob(storedBPM, min: 40, max: 240) { v in
            core.set(.metroBPM, v)
            UserDefaults.standard.set(v, forKey: "AutoHarp.metroBPM")
        }
        let storedSync = UserDefaults.standard.object(forKey: "AutoHarp.metroSync") as? Bool ?? true
        metroSyncParam = Knob(storedSync ? 1 : 0) { v in
            core.set(.metroSync, v)
            UserDefaults.standard.set(v >= 0.5, forKey: "AutoHarp.metroSync")
        }

        droneWave = bind(.droneWave, 0, min: 0, max: 3)
        droneAttack = bind(.droneAttack, 5, min: 1, max: 2000)
        droneRelease = bind(.droneRelease, 150, min: 10, max: 4000)
        droneSustain = bind(.droneSustain, 1)
        droneVolume = bind(.droneVolume, 0.3)
        strumWave = bind(.strumWave, 2, min: 0, max: 3)
        strumAttack = bind(.strumAttack, 2, min: 1, max: 2000)
        strumRelease = bind(.strumRelease, 2500, min: 10, max: 4000)
        strumSustain = bind(.strumSustain, 0)
        strumVolume = bind(.strumVolume, 0.18)
        metroWave = bind(.metroWave, 3, min: 0, max: 3)
        metroAttack = bind(.metroAttack, 1, min: 1, max: 2000)
        metroRelease = bind(.metroRelease, 40, min: 10, max: 4000)
        metroSustain = bind(.metroSustain, 0)
        metroVolume = bind(.metroVolume, 0.35)

        dsp.kernel.setDroneEnabled(droneEnabled)
        dsp.kernel.setSplitMIDI(splitMIDI)
        startMIDIFlush()

        core.kernel.setMIDI1OutputEventBlock { _, _, length, data in
            if length >= 3 {
                let status = data[0]
                if status & 0xF0 == 0x90 || status & 0xF0 == 0x80 {
                    MIDIManager.sendNote(on: status & 0xF0 == 0x90 && data[2] > 0, data[1], velocity: data[2], channel: status & 0x0F)
                }
            }
            return noErr
        }
        Harp.shared.play = { on, note in
            if on { core.kernel.strumVoiceOn(note) } else { core.kernel.strumVoiceOff(note) }
        }
    }

    func arm() {
        guard !armed else { return }
        armed = true
        observeAudio()
        MIDIManager.arm()
        wake()
    }

    func applyChord() {
        dsp.kernel.applyLiveChord()
    }

    func secondsToNextBeat() -> TimeInterval {
        dsp.kernel.secondsToNextBeat()
    }

    func tapTempo() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = tempoTaps.last, now - last > 2 { tempoTaps.removeAll() }
        tempoTaps.append(now)
        guard tempoTaps.count >= 2 else { return }
        let recent = Array(tempoTaps.suffix(5))
        var sum: TimeInterval = 0
        for i in 1..<recent.count { sum += recent[i] - recent[i - 1] }
        metroBPM = Float(min(240, max(40, 60 / (sum / TimeInterval(recent.count - 1)))))
    }

    private func startMIDIFlush() {
        guard midiFlush == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "autoharp.midi.flush"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        let dsp = self.dsp
        timer.setEventHandler { dsp.kernel.flushMIDI() }
        timer.resume()
        midiFlush = timer
    }

    private func wake() {
        MIDIManager.outputEnabled = true
        activateSession()
        if source == nil { build() }
        resumeIfNeeded()
    }

    private func sleep() {
        MIDIManager.outputEnabled = false
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try? session.setActive(true)
    }

    /// iOS already stopped us. Do not reconnect or rebuild — that is the glitch.
    private func resumeIfNeeded() {
        guard inForeground else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
    }

    /// Build once. Rotate/screenshot must never get here, stop the engine, or deactivate the session.
    private func build() {
        let sr = max(AVAudioSession.sharedInstance().sampleRate, 44100)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
        dsp.kernel.initialize(format.sampleRate)
        let dsp = self.dsp
        let node = AVAudioSourceNode { _, timestamp, frameCount, abl in
            dsp.render(timestamp.pointee.mSampleTime, frameCount, abl)
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
    }

    private func observeAudio() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw),
                      type == .ended else { return }
                self?.resumeIfNeeded()
            }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeIfNeeded() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard UIApplication.shared.applicationState == .background else { return }
                self?.inForeground = false
                self?.sleep()
            }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inForeground = true
                self?.wake()
            }
        }
    }
}
