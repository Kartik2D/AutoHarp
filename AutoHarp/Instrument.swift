//
//  Instrument.swift
//  AutoHarp
//
//  Sampler monitor + MIDI out. The loaded sound decides how a note rings.
//

import AVFoundation
import Foundation
import UIKit

struct Voice: Identifiable {
    /// A SoundFont program, or a negative wave number.
    let program: Int
    let name: String
    var id: Int { program }

    static let waves = Wave.allCases.map { Voice(program: -1 - $0.rawValue, name: $0.name) }
}

@Observable
@MainActor
final class Instrument {
    /// GeneralUser GS bank 0. Drone voices sustain while held; strum voices fade on their own.
    static let droneVoices = [
        Voice(program: 89, name: "Warm Pad"),
        Voice(program: 94, name: "Halo Pad"),
        Voice(program: 91, name: "Space Voice"),
        Voice(program: 49, name: "Strings"),
        Voice(program: 52, name: "Choir"),
        Voice(program: 19, name: "Pipe Organ"),
        Voice(program: 20, name: "Reed Organ"),
        Voice(program: 21, name: "Accordion"),
    ]
    static let strumVoices = [
        Voice(program: 46, name: "Harp"),
        Voice(program: 24, name: "Nylon Guitar"),
        Voice(program: 25, name: "Steel Guitar"),
        Voice(program: 6, name: "Harpsichord"),
        Voice(program: 15, name: "Dulcimer"),
        Voice(program: 45, name: "Pizzicato Strings"),
        Voice(program: 108, name: "Kalimba"),
        Voice(program: 11, name: "Vibraphone"),
        Voice(program: 8, name: "Celesta"),
        Voice(program: 10, name: "Music Box"),
    ]
    /// Two full parts of stacked notes summed at 0 dB trip the device limiter.
    private static let headroom: Float = -12

    private let engine = AVAudioEngine()
    private let metro = MetroClick()
    private let droneOsc = Oscillator()
    private let strumOsc = Oscillator()
    private var built = false
    private var droneSampler: AVAudioUnitSampler?
    private var strumSampler: AVAudioUnitSampler?

    var droneEnabled = UserDefaults.standard.object(forKey: "AutoHarp.droneEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(droneEnabled, forKey: "AutoHarp.droneEnabled") }
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
        didSet { engine.mainMixerNode.outputVolume = soundEnabled ? 1 : 0 }
    }

    var layout = min(1, UserDefaults.standard.integer(forKey: "AutoHarp.chordLayout")) {
        didSet { UserDefaults.standard.set(layout, forKey: "AutoHarp.chordLayout") }
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
        }
    }

    var metroEnabled = false {
        didSet { metro.set(on: metroEnabled) }
    }

    var metroBPM: Float = (UserDefaults.standard.object(forKey: "AutoHarp.metroBPM") as? Float) ?? 120 {
        didSet {
            let bpm = min(240, max(40, metroBPM))
            if bpm != metroBPM { metroBPM = bpm; return }
            UserDefaults.standard.set(bpm, forKey: "AutoHarp.metroBPM")
            metro.set(bpm: bpm)
        }
    }

    var metroSync = UserDefaults.standard.object(forKey: "AutoHarp.metroSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(metroSync, forKey: "AutoHarp.metroSync") }
    }

    var metroLevel: Float = (UserDefaults.standard.object(forKey: "AutoHarp.metroLevel") as? Float) ?? 0.35 {
        didSet {
            UserDefaults.standard.set(metroLevel, forKey: "AutoHarp.metroLevel")
            metro.set(volume: metroLevel)
        }
    }

    var droneLevel: Float = (UserDefaults.standard.object(forKey: "AutoHarp.droneLevel") as? Float) ?? (Float(100) / 127) {
        didSet {
            UserDefaults.standard.set(droneLevel, forKey: "AutoHarp.droneLevel")
            Notes.shared.velocity[Notes.Part.drone.rawValue] = Self.velocity(droneLevel)
            applyGain(droneLevel, droneSampler)
        }
    }

    var strumLevel: Float = (UserDefaults.standard.object(forKey: "AutoHarp.strumLevel") as? Float) ?? (Float(100) / 127) {
        didSet {
            UserDefaults.standard.set(strumLevel, forKey: "AutoHarp.strumLevel")
            Notes.shared.velocity[Notes.Part.strum.rawValue] = Self.velocity(strumLevel)
            applyGain(strumLevel, strumSampler)
        }
    }

    var droneProgram = UserDefaults.standard.object(forKey: "AutoHarp.droneProgram") as? Int ?? 89 {
        didSet { UserDefaults.standard.set(droneProgram, forKey: "AutoHarp.droneProgram"); load(.drone) }
    }

    var strumProgram = UserDefaults.standard.object(forKey: "AutoHarp.strumProgram") as? Int ?? 46 {
        didSet { UserDefaults.standard.set(strumProgram, forKey: "AutoHarp.strumProgram"); load(.strum) }
    }

    /// A wave number for the built-in synth, or nil when the sampler plays.
    static func wave(_ program: Int) -> Wave? {
        let raw = -1 - program
        return Wave(rawValue: raw)
    }

    private var tempoTaps: [TimeInterval] = []
    private var armed = false
    private var inForeground = true

    init() {
        Notes.shared.velocity[Notes.Part.drone.rawValue] = Self.velocity(droneLevel)
        Notes.shared.velocity[Notes.Part.strum.rawValue] = Self.velocity(strumLevel)
        metro.set(bpm: metroBPM)
        metro.set(volume: metroLevel)
    }

    func arm() {
        guard !armed else { return }
        armed = true
        observeAudio()
        MIDIManager.arm()
        wake()
    }

    func secondsToNextBeat() -> TimeInterval {
        metro.secondsToNextBeat()
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

    static func velocity(_ level: Float) -> UInt8 {
        UInt8(max(1, min(127, Int((level * 127).rounded()))))
    }

    private func load(_ part: Notes.Part) {
        let program = part == .drone ? droneProgram : strumProgram
        let ch = part.rawValue
        let osc = part == .drone ? droneOsc : strumOsc
        let level = part == .drone ? droneLevel : strumLevel
        osc.set(level: level)
        osc.set(release: part == .strum ? 2.5 : 0)
        if let wave = Self.wave(program) {
            osc.set(wave: wave)
            Notes.shared.wave[ch] = wave.rawValue
        } else {
            Notes.shared.wave[ch] = -1
            if let sampler = part == .drone ? droneSampler : strumSampler,
               let url = Bundle.main.url(forResource: "GeneralUser-GS", withExtension: "sf2") {
                try? sampler.loadSoundBankInstrument(at: url, program: UInt8(clamping: program), bankMSB: 0x79, bankLSB: 0)
            }
        }
        Notes.shared.replay(part)
    }

    private func applyGain(_ level: Float, _ sampler: AVAudioUnitSampler?) {
        sampler?.masterGain = level <= 0.001 ? -96 : 20 * log10(level) + Self.headroom
        droneOsc.set(level: droneLevel)
        strumOsc.set(level: strumLevel)
    }

    private func wake() {
        MIDIManager.outputEnabled = true
        activateSession()
        if !built { build() }
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
        let rate = max(AVAudioSession.sharedInstance().sampleRate, 44100)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        metro.prepare(rate: rate)
        droneOsc.prepare(rate: rate)
        strumOsc.prepare(rate: rate)
        Notes.shared.synth = [droneOsc, strumOsc]
        let drone = AVAudioUnitSampler()
        let strum = AVAudioUnitSampler()
        droneSampler = drone
        strumSampler = strum
        Notes.shared.sampler[Notes.Part.drone.rawValue] = drone
        Notes.shared.sampler[Notes.Part.strum.rawValue] = strum
        let click = metro
        let droneWave = droneOsc
        let strumWave = strumOsc
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            click.render(frameCount, abl)
            return noErr
        }
        let droneSynth = AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            droneWave.render(frameCount, abl)
            return noErr
        }
        let strumSynth = AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            strumWave.render(frameCount, abl)
            return noErr
        }
        engine.attach(drone)
        engine.attach(strum)
        engine.attach(node)
        engine.attach(droneSynth)
        engine.attach(strumSynth)
        engine.connect(drone, to: engine.mainMixerNode, format: nil)
        engine.connect(strum, to: engine.mainMixerNode, format: nil)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(droneSynth, to: engine.mainMixerNode, format: format)
        engine.connect(strumSynth, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        applyGain(droneLevel, drone)
        applyGain(strumLevel, strum)
        engine.mainMixerNode.outputVolume = soundEnabled ? 1 : 0
        load(.drone)
        load(.strum)
        engine.prepare()
        built = true
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
