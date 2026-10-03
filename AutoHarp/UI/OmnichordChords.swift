//
//  OmnichordChords.swift
//  AutoHarpExtension
//
//  Notes match https://omnichord.amplib.app/ (chords.js + @amplib/music-theory).
//

import Foundation
import SwiftUI

enum HarpTheme: Int, CaseIterable {
    case classic, signal, ion, light, gelato, orchid

    var title: String {
        switch self {
        case .classic: "Classic"
        case .signal: "Signal"
        case .ion: "Ion"
        case .light: "Light"
        case .gelato: "Gelato"
        case .orchid: "Orchid"
        }
    }

    var isLight: Bool {
        switch self {
        case .light, .gelato, .orchid: true
        default: false
        }
    }

    var ink: Color { self == .classic ? .white : .black }
    var flash: Color { isLight ? .black : .white }

    fileprivate var rainbow: Bool { self == .classic || self == .light }

    fileprivate var notes: [UInt32] {
        switch self {
        case .classic:
            [0xCC1612, 0xF25E00, 0xF29200, 0xF5CB00, 0x93C01F, 0x5BBA59,
             0x23C29A, 0x249FD4, 0x4E79D0, 0x5C44D0, 0x9435C0, 0xA8006A]
        case .light:
            [0x2EBEA8, 0x5BC94A, 0xE0A830, 0xF09070, 0xFF7A90, 0xE85A9A,
             0xC060C8, 0x8878E0, 0x5AA8E0, 0x3DB8C8, 0xE07070, 0xD88840]
        case .signal:
            [0xFCF660, 0xB2D942, 0x52C33F, 0x7ED4C8]
        case .ion:
            [0x53FFE2, 0x48D1E7, 0x4AB0E0, 0x9BB0FF]
        case .gelato:
            [0xEE6A7C, 0xF08080, 0xE0A830, 0x2EBEA0, 0x2AA8B8, 0xD46B8A]
        case .orchid:
            [0xC86AD0, 0xD070B0, 0x8A60D8, 0xE07090, 0x8878E8]
        }
    }

    fileprivate var page: UInt32 {
        switch self {
        case .classic: 0x141414
        case .signal: 0x201533
        case .ion: 0x1C0635
        case .light: 0xFFF8EE
        case .gelato: 0xFFF1E8
        case .orchid: 0xF7E8D0
        }
    }

    fileprivate var padIdle: UInt32 {
        switch self {
        case .classic: 0x737373
        case .signal: 0x3A3048
        case .ion: 0x3A2060
        case .light: 0xE8D8C0
        case .gelato: 0xF0D8D0
        case .orchid: 0xE8D4C0
        }
    }

    fileprivate var pianoWhite: UInt32 {
        switch self {
        case .classic: 0x5C5C5C
        case .signal: 0x5A5440
        case .ion: 0x4A4870
        case .light: 0xE8D4B8
        case .gelato: 0xE8C8BC
        case .orchid: 0xE0C8B0
        }
    }

    fileprivate var pianoBlack: UInt32 {
        switch self {
        case .classic: 0x383838
        case .signal: 0x32283C
        case .ion: 0x2C2050
        case .light: 0xA88878
        case .gelato: 0xA07070
        case .orchid: 0x8A70B0
        }
    }

    fileprivate var tintMix: Double { isLight ? 0.22 : 0.32 }
}

private struct HarpThemeKey: EnvironmentKey {
    static let defaultValue = HarpTheme.classic
}

extension EnvironmentValues {
    var harpTheme: HarpTheme {
        get { self[HarpThemeKey.self] }
        set { self[HarpThemeKey.self] = newValue }
    }
}

enum OmnichordChords {
    /// Chromatic, like the reference (`Note.notations`).
    static let rootPC = Array(0..<12)
    static let rootNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let suffixes = ["", "m", "M7", "m7", "7", "+", "°", "sus2", "sus4"]
    static let intervals: [[Int]] = [
        [0, 4, 7],
        [0, 3, 7],
        [0, 4, 7, 11],
        [0, 3, 7, 10],
        [0, 4, 7, 10],
        [0, 4, 8],
        [0, 3, 6],
        [0, 2, 7],
        [0, 5, 7]
    ]
    static var qualityCount: Int { suffixes.count }

    /// Clockwise from C at 12 o'clock.
    static let fifthsPC = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]

    static func label(root: Int, quality: Int) -> String {
        rootNames[root % 12] + suffixes[quality]
    }

    /// Ring 0 = outer major, ring 1 = relative minor, ring 2 = V7 of that major
    /// (C / Am / G7 share the 12 o'clock wedge).
    static func fifthsChord(slice: Int, ring: Int) -> (root: Int, quality: Int) {
        let major = fifthsPC[((slice % 12) + 12) % 12]
        switch ring {
        case 0: return (major, 0)
        case 1: return ((major + 9) % 12, 1)
        default: return ((major + 7) % 12, 4)
        }
    }

    static func color(pc: Int, fifths: Bool = false, theme: HarpTheme) -> Color {
        rgb(noteHex(pc: pc, fifths: fifths, theme: theme))
    }

    static func page(on: Bool, pc: Int, fifths: Bool, theme: HarpTheme) -> Color {
        if !on || !theme.rainbow { return rgb(theme.page) }
        return rgb(noteHex(pc: pc, fifths: fifths, theme: theme), mix: theme.tintMix, onto: theme.page)
    }

    static func idlePad(theme: HarpTheme) -> Color { rgb(theme.padIdle) }

    static func loopPad(slot: Int, loaded: Bool, theme: HarpTheme) -> Color {
        let pool = theme.notes.filter { !isRecordRed($0) }
        let notes = pool.isEmpty ? theme.notes : pool
        let hex = notes[(slot * (theme.rainbow ? 2 : 1)) % notes.count]
        return rgb(hex, mix: loaded ? 1 : 0.42, onto: theme.page)
    }

    static func piano(black: Bool, theme: HarpTheme) -> Color {
        if theme == .classic {
            return neutral(brightness: black ? 0.22 : 0.36)
        }
        return rgb(black ? theme.pianoBlack : theme.pianoWhite)
    }

    /// Grey used when no chord is held (reference `neutralFor`).
    static func neutral(brightness: Double) -> Color {
        Color(hue: 0, saturation: 0, brightness: brightness)
    }

    /// Record LED is `UIColor.red`; skip hues that read as the same thing.
    private static func isRecordRed(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maxv = max(r, g, b), minv = min(r, g, b), d = maxv - minv
        guard d > 0.15, maxv > 0.35 else { return false }
        let h: Double
        if maxv == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxv == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return h * 60 < 20 || h * 60 > 340
    }

    private static func noteHex(pc: Int, fifths: Bool, theme: HarpTheme) -> UInt32 {
        let i: Int
        if fifths {
            i = fifthsPC.firstIndex(of: ((pc % 12) + 12) % 12) ?? 0
        } else {
            i = ((pc % 12) + 12) % 12
        }
        let notes = theme.notes
        return notes[theme.rainbow ? i : i % notes.count]
    }

    private static func rgb(_ hex: UInt32, mix: Double = 1, onto: UInt32 = 0) -> Color {
        func ch(_ h: UInt32, _ shift: UInt32) -> Double { Double((h >> shift) & 0xFF) / 255 }
        let a = 1 - mix
        return Color(
            red: ch(hex, 16) * mix + ch(onto, 16) * a,
            green: ch(hex, 8) * mix + ch(onto, 8) * a,
            blue: ch(hex, 0) * mix + ch(onto, 0) * a
        )
    }

    static func padNotes(pc: Int, quality: Int) -> [UInt8] {
        var notes = [UInt8(36 + pc)]
        for interval in intervals[quality] {
            notes.append(UInt8(min(127, 48 + pc + interval)))
        }
        return notes
    }

    static func harpNotes(pc: Int, quality: Int) -> [UInt8] {
        var notes = [UInt8]()
        for octave in 2...6 {
            for interval in intervals[quality] {
                let midi = (octave + 1) * 12 + pc + interval
                let absOctave = midi / 12 - 1
                if absOctave <= 6, midi >= 0, midi <= 127 {
                    notes.append(UInt8(midi))
                }
            }
        }
        return notes.reversed()
    }
}
