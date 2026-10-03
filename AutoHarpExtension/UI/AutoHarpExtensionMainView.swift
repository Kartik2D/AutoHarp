//
//  AutoHarpExtensionMainView.swift
//  AutoHarpExtension
//
//  Standalone UI lives in the app. MIDI FX can host the harp here later.
//

import SwiftUI

struct AutoHarpExtensionMainView: View {
    var parameterTree: ObservableAUParameterGroup
    var secondsToNextBeat: () -> TimeInterval = { 0 }

    var body: some View {
        Color.clear
    }
}
