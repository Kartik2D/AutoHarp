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
            DisclosureGroup("Sound") {
                Toggle("Drone", isOn: $instrument.droneEnabled)
                partControls("Drone", Voice.waves + Instrument.droneVoices, $instrument.droneProgram, level: $instrument.droneLevel)
                partControls("Strum", Voice.waves + Instrument.strumVoices, $instrument.strumProgram, level: $instrument.strumLevel)
            }
            DisclosureGroup("Metronome") {
                labeledSlider("Tempo", value: "\(Int(instrument.metroBPM.rounded())) BPM") {
                    Slider(value: $instrument.metroBPM, in: 40...240, step: 1)
                }
                Button("Tap Tempo") { instrument.tapTempo() }
                Toggle("Snap to Beat", isOn: $instrument.metroSync)
                labeledSlider("Level", value: "\(Int((instrument.metroLevel * 100).rounded()))%") {
                    Slider(value: $instrument.metroLevel, in: 0...1)
                }
            }
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
                    row("Theme", instrument.theme.title)
                }
                Menu {
                    Button { instrument.coloring = 0 } label: {
                        HStack {
                            Text("Chromatic")
                            if instrument.coloring == 0 { Image(systemName: "checkmark") }
                        }
                    }
                    Button { instrument.coloring = 1 } label: {
                        HStack {
                            Text("Fifths")
                            if instrument.coloring == 1 { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    row("Coloring", instrument.coloring == 0 ? "Chromatic" : "Fifths")
                }
                Toggle("Playable Piano Keys", isOn: $instrument.pianoEnabled)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }

    @ViewBuilder
    private func partControls(_ title: String, _ voices: [Voice], _ program: Binding<Int>, level: Binding<Float>) -> some View {
        Text(title).font(.subheadline).foregroundStyle(.secondary)
        Picker("Instrument", selection: program) {
            ForEach(voices) { Text($0.name).tag($0.program) }
        }
        labeledSlider("Level", value: "\(Instrument.velocity(level.wrappedValue))") {
            Slider(value: level, in: 0...1)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func labeledSlider(_ title: String, value: String, @ViewBuilder slider: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.subheadline)
            slider()
        }
        .padding(.vertical, 2)
    }
}

private struct HarpDetail: View {
    let instrument: Instrument

    var body: some View {
        @Bindable var host = instrument
        CircleOfFifthsView(instrument: instrument)
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

#Preview {
    ContentView(instrument: Instrument())
}
