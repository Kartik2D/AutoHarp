//
//  AutoHarpApp.swift
//  AutoHarp
//

import SwiftUI

@main
struct AutoHarpApp: App {
    private let instrument = Instrument()

    var body: some Scene {
        WindowGroup {
            ContentView(instrument: instrument)
        }
    }
}
