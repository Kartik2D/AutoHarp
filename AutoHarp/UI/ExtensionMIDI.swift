//
//  ExtensionMIDI.swift
//  AutoHarpExtension
//
//  Harp voices. MIDI out is kernel-only (sendMIDI), never consulted here.
//

import Foundation

final class Harp: @unchecked Sendable {
    static let shared = Harp()
    var play: ((Bool, UInt8) -> Void)?

    func pluck(_ note: UInt8) { play?(true, note) }
    func release(_ note: UInt8) { play?(false, note) }
}
