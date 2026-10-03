//
//  ContentView.swift
//  AutoHarp
//

import CoreMIDI
import SwiftUI

struct ContentView: View {
    let instrument: Instrument

    var body: some View {
        NavigationSplitView(preferredCompactColumn: .constant(.detail)) {
            SettingsList(instrument: instrument)
        } detail: {
            HarpDetail(instrument: instrument)
        }
        .containerBackground(.clear, for: .navigation)
        .onAppear { instrument.arm() }
    }
}

private struct SettingsList: View {
    @Bindable var instrument: Instrument

    var body: some View {
        List {
            DisclosureGroup("View") {
                Menu {
                    ForEach(HarpTheme.allCases, id: \.self) { theme in
                        Button {
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) { instrument.theme = theme }
                        } label: {
                            HStack {
                                Text(theme.title)
                                if theme == instrument.theme { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Text(instrument.theme.title).foregroundStyle(.secondary)
                    }
                }
                Menu {
                    Button {
                        instrument.coloring = 0
                    } label: {
                        HStack {
                            Text("Chromatic")
                            if instrument.coloring == 0 { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        instrument.coloring = 1
                    } label: {
                        HStack {
                            Text("Fifths")
                            if instrument.coloring == 1 { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    HStack {
                        Text("Coloring")
                        Spacer()
                        Text(instrument.coloring == 0 ? "Chromatic" : "Fifths")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Playable Piano Keys", isOn: $instrument.pianoEnabled)
            }
            DisclosureGroup("MIDI") {
                Toggle("Separate Drone / Strum Channels", isOn: $instrument.splitMIDI)
            }
            DisclosureGroup("Metronome") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tempo")
                        Spacer()
                        Text("\(Int(instrument.metroBPM.rounded())) BPM")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    Slider(value: $instrument.metroBPM, in: 40...240, step: 1)
                }
                .padding(.vertical, 2)
                Button("Tap Tempo") { instrument.tapTempo() }
                Toggle("Snap to Beat", isOn: $instrument.metroSync)
                DisclosureGroup("Voice") {
                    SynthControls(wave: instrument.metroWave, attack: instrument.metroAttack, release: instrument.metroRelease, sustain: instrument.metroSustain, volume: instrument.metroVolume)
                }
            }
            DisclosureGroup("Drone") {
                SynthControls(enabled: $instrument.droneEnabled, wave: instrument.droneWave, attack: instrument.droneAttack, release: instrument.droneRelease, sustain: instrument.droneSustain, volume: instrument.droneVolume)
            }
            DisclosureGroup("Strum") {
                SynthControls(wave: instrument.strumWave, attack: instrument.strumAttack, release: instrument.strumRelease, sustain: instrument.strumSustain, volume: instrument.strumVolume)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }
}

private struct HarpDetail: View {
    let instrument: Instrument

    var body: some View {
        @Bindable var host = instrument
        CircleOfFifthsView(
            noteParam: host.noteParam,
            gateParam: host.gateParam,
            qualityParam: host.qualityParam,
            layoutParam: host.layoutParam,
            coloringParam: host.coloringParam,
            metroOnParam: host.metroOnParam,
            metroBPMParam: host.metroBPMParam,
            metroSyncParam: host.metroSyncParam,
            pianoEnabled: host.pianoEnabled,
            retuneChord: { host.applyChord() },
            secondsToNextBeat: { host.secondsToNextBeat() }
        )
        .environment(\.harpTheme, host.theme)
        .preferredColorScheme(host.theme.isLight ? .light : .dark)
        .toolbar { chrome }
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden)
    }

    @ToolbarContentBuilder
    private var chrome: some ToolbarContent {
        @Bindable var host = instrument
        let midi = Bindable(MIDIManager.shared)
        ToolbarItem(placement: .topBarLeading) {
            Toggle(
                "Sound",
                systemImage: host.soundEnabled ? "speaker.wave.2" : "speaker.slash",
                isOn: $host.soundEnabled
            )
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
        }
        ToolbarSpacer(.fixed, placement: .topBarLeading)
        ToolbarItem(placement: .topBarLeading) {
            Toggle(
                "Metronome",
                systemImage: "metronome",
                isOn: $host.metroEnabled
            )
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
        }
        ToolbarSpacer(.fixed, placement: .topBarLeading)
        ToolbarItem(placement: .topBarLeading) {
            Picker("Layout", selection: $host.layout) {
                Image(systemName: "square.grid.3x3").tag(0)
                Image(systemName: "circle.grid.cross").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("MIDI Out", selection: midi.selectedID) {
                    Text("None").tag(MIDIEndpointRef(0))
                    ForEach(midi.wrappedValue.destinations) { dest in
                        Text(dest.name).tag(dest.id)
                    }
                }
            } label: {
                Label(midi.wrappedValue.selectedName, systemImage: "cable.connector")
            }
            .labelStyle(.iconOnly)
        }
    }
}

private struct SynthControls: View {
    var enabled: Binding<Bool>?
    var wave: Knob
    var attack: Knob
    var release: Knob
    var sustain: Knob
    var volume: Knob

    var body: some View {
        if let enabled {
            Toggle("Enabled", isOn: enabled)
        }
        WavePicker(param: wave)
        ParamSlider(title: "Attack", param: attack, suffix: "ms")
        ParamSlider(title: "Release", param: release, suffix: "ms")
        ParamSlider(title: "Sustain", param: sustain, percent: true)
        ParamSlider(title: "Velocity", param: volume, percent: true)
    }
}

private struct WavePicker: View {
    var param: Knob

    var body: some View {
        Picker("Waveform", selection: wave) {
            Text("Sine").tag(0)
            Text("Triangle").tag(1)
            Text("Saw").tag(2)
            Text("Square").tag(3)
        }
    }

    private var wave: Binding<Int> {
        Binding(get: { Int(param.value.rounded()) }, set: { param.value = Float($0) })
    }
}

private struct ParamSlider: View {
    let title: String
    var param: Knob
    var suffix = ""
    var percent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            Slider(value: Bindable(param).value, in: param.min...param.max)
        }
        .padding(.vertical, 2)
    }

    private var label: String {
        if percent { return String(format: "%.0f%%", param.value * 100) }
        if suffix.isEmpty { return String(format: "%.2f", param.value) }
        return String(format: "%.0f \(suffix)", param.value)
    }
}

#Preview {
    ContentView(instrument: Instrument())
}
