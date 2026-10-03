//
//  MIDIManager.swift
//  AutoHarp
//
//  Created by Kartik Vinayak on 9/11/26.
//

import AudioToolbox
import Foundation
import CoreMIDI
import Observation

@MainActor
@Observable
final class MIDIManager: Identifiable {
    struct Destination: Identifiable, Hashable {
        let id: MIDIEndpointRef
        let name: String
    }

    let id = UUID()
    static let shared = MIDIManager()

    private(set) var destinations: [Destination] = []
    /// Bound to the picker; user choices are remembered by name so they survive the target app relaunching.
    var selectedID: MIDIEndpointRef = 0 {
        didSet {
            MIDIManager.selectedDest = selectedID
            guard !autoSelecting else { return }
            UserDefaults.standard.set(selectedID == 0 ? "" : Self.endpointName(selectedID), forKey: "AutoHarp.midiOutName")
        }
    }
    private var autoSelecting = false
    static let virtualSourceName = "AutoHarp (all apps)"

    var selectedName: String {
        destinations.first(where: { $0.id == selectedID })?.name ?? "None"
    }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()

    nonisolated(unsafe) private static var outputSource = MIDIEndpointRef()
    nonisolated(unsafe) private static var outputPort = MIDIPortRef()
    nonisolated(unsafe) private static var selectedDest = MIDIEndpointRef()
    /// Audio-thread MIDISend during session teardown deadlocks CoreMIDI (lock screen / Control Center).
    nonisolated(unsafe) static var outputEnabled = true

    nonisolated static func sendNote(on: Bool, _ note: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) {
        guard outputEnabled else { return }
        let src = outputSource, port = outputPort, dest = selectedDest
        let status: UInt8 = (on ? 0x90 : 0x80) | (channel & 0x0F)
        midiSendQ.async {
            guard outputEnabled else { return }
            emitMIDI1([status, note, on ? velocity : 0], source: src, port: port, dest: dest)
        }
    }

    nonisolated static func send(_ eventList: UnsafePointer<MIDIEventList>) {
        guard outputEnabled else { return }
        var ctx = SendContext(source: outputSource, port: outputPort, dest: selectedDest)
        MIDIEventListForEachEvent(eventList, { context, _, message in
            guard let context else { return }
            let dests = context.assumingMemoryBound(to: SendContext.self).pointee
            var status: UInt8 = 0
            var note: UInt8 = 0
            var vel: UInt8 = 0
            switch message.type {
            case .channelVoice2:
                note = message.channelVoice2.note.number
                switch message.channelVoice2.status {
                case .noteOn:
                    status = 0x90
                    vel = UInt8(min(127, message.channelVoice2.note.velocity >> 9))
                    if vel == 0 { vel = 1 }
                case .noteOff:
                    status = 0x80
                    vel = 0
                default:
                    return
                }
            case .channelVoice1:
                note = message.channelVoice1.note.number
                switch message.channelVoice1.status {
                case .noteOn:
                    status = 0x90
                    vel = message.channelVoice1.note.velocity
                    if vel == 0 { vel = 1 }
                case .noteOff:
                    status = 0x80
                    vel = 0
                default:
                    return
                }
            default:
                return
            }
            emitMIDI1([status, note, vel], source: dests.source, port: dests.port, dest: dests.dest)
        }, &ctx)
    }

    private struct SendContext {
        var source: MIDIEndpointRef
        var port: MIDIPortRef
        var dest: MIDIEndpointRef
    }

    func refreshDestinations() {
        var list = [Destination]()
        // Our virtual source is one option among the others: exactly one output is ever active.
        if virtualSource != 0 {
            list.append(Destination(id: virtualSource, name: Self.virtualSourceName))
        }
        for index in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(index)
            list.append(Destination(id: dest, name: Self.endpointName(dest)))
        }
        destinations = list
        autoSelecting = true
        defer { autoSelecting = false }
        let stored = UserDefaults.standard.string(forKey: "AutoHarp.midiOutName")
        if let stored, let match = list.first(where: { $0.name == stored }) {
            selectedID = match.id            // the remembered target is (back) online
        } else if stored == "" {
            selectedID = 0                   // explicit None stays None
        } else if !list.contains(where: { $0.id == selectedID }) {
            // First launch or the remembered target is offline: temporary fallback, not persisted.
            selectedID = list.first(where: { $0.name.localizedCaseInsensitiveContains("Logic") })?.id
                ?? list.first?.id ?? 0
        }
    }

    /// Never listen to our own virtual sources (host's or extension's) or the AU hears itself.
    nonisolated private static func isOwnSource(_ source: MIDIEndpointRef) -> Bool {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(source, kMIDIPropertyName, &name)
        return (name?.takeRetainedValue() as String?) == "AutoHarp"
    }

    nonisolated static func arm() {
        midiSendQ.async { install() }
    }

    nonisolated private static func install() {
        guard outputSource == 0, outputPort == 0 else { return }
        var client = MIDIClientRef()
        var inPort = MIDIPortRef()
        var outPort = MIDIPortRef()
        var source = MIDIEndpointRef()
        let name = (Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "MIDIManager") + "_MIDIClient"
        guard MIDIClientCreateWithBlock(name as CFString, &client, { notificationPointer in
            let pointer = UnsafeRawPointer(notificationPointer)
            switch notificationPointer.pointee.messageID {
            case .msgObjectAdded:
                let msg = pointer.assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self).pointee
                let child = msg.child
                let isSource = msg.childType == .source
                Task { @MainActor in
                    if isSource, !isOwnSource(child) {
                        _ = MIDIPortConnectSource(MIDIManager.shared.port, child, nil)
                    }
                    MIDIManager.shared.refreshDestinations()
                }
            case .msgObjectRemoved:
                let msg = pointer.assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self).pointee
                let child = msg.child
                Task { @MainActor in
                    if msg.childType == .source {
                        _ = MIDIPortDisconnectSource(MIDIManager.shared.port, child)
                    }
                    MIDIManager.shared.refreshDestinations()
                }
            case .msgSetupChanged:
                Task { @MainActor in MIDIManager.shared.refreshDestinations() }
            default:
                break
            }
        }) == noErr else { return }

        _ = MIDIInputPortCreateWithProtocol(client, "MIDI Input Port" as CFString, ._2_0, &inPort) { _, _ in }
        if MIDIOutputPortCreate(client, "AutoHarp Out" as CFString, &outPort) == noErr {
            outputPort = outPort
        }
        if MIDISourceCreateWithProtocol(client, "AutoHarp" as CFString, ._1_0, &source) == noErr {
            MIDIObjectSetStringProperty(source, kMIDIPropertyDisplayName, "AutoHarp" as CFString)
            outputSource = source
        }
        for index in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(index)
            if !isOwnSource(src) { _ = MIDIPortConnectSource(inPort, src, nil) }
        }
        Task { @MainActor in
            let midi = MIDIManager.shared
            midi.client = client
            midi.port = inPort
            midi.outPort = outPort
            midi.virtualSource = source
            midi.refreshDestinations()
        }
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr,
           let value = name?.takeRetainedValue() as String?, !value.isEmpty {
            return value
        }
        name = nil
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) == noErr,
           let value = name?.takeRetainedValue() as String?, !value.isEmpty {
            return value
        }
        return "MIDI \(endpoint)"
    }
}

private let midiSendQ = DispatchQueue(label: "autoharp.midi")

nonisolated private func emitMIDI1(_ bytes: [UInt8], source: MIDIEndpointRef, port: MIDIPortRef, dest: MIDIEndpointRef) {
    var packetList = MIDIPacketList()
    var packet = MIDIPacketListInit(&packetList)
    bytes.withUnsafeBufferPointer { buf in
        packet = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, 3, buf.baseAddress!)
    }
    if dest == 0 { return }                       // None: standalone, no MIDI leaves the app
    if dest == source {
        MIDIReceived(source, &packetList)          // broadcast on our virtual source
    } else if port != 0 {
        MIDISend(port, dest, &packetList)          // a specific destination
    }
}
