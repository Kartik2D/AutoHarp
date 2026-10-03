//
//  AudioUnitViewController.swift
//  AutoHarpExtension
//
//  Created by Kartik Vinayak on 9/11/26.
//

import CoreAudioKit
import os
import SwiftUI
#if os(macOS)
import AppKit
#endif

private let log = Logger(subsystem: "example.AutoHarpExtension", category: "AudioUnitViewController")

@MainActor
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    var audioUnit: AUAudioUnit?
    
    var hostingController: HostingController<AutoHarpExtensionMainView>?

	/* iOS View lifcycle
	public override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		// Recreate any view related resources here..
	}

	public override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		// Destroy any view related content here..
	}
	*/

	/* macOS View lifcycle
	public override func viewWillAppear() {
		super.viewWillAppear()
		
		// Recreate any view related resources here..
	}

	public override func viewDidDisappear() {
		super.viewDidDisappear()

		// Destroy any view related content here..
	}
	*/

	deinit {
	}

    public override func viewDidLoad() {
        super.viewDidLoad()
        #if os(macOS)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        #else
        view.backgroundColor = .clear
        #endif
        
        // Accessing the `audioUnit` parameter prompts the AU to be created via createAudioUnit(with:)
        guard let audioUnit = self.audioUnit else {
            return
        }
        configureSwiftUIView(audioUnit: audioUnit)
    }
    
	nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let make = { try self.installAudioUnit(componentDescription) }
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(make)
        }
        return try DispatchQueue.main.sync(execute: make)
	}

    private func installAudioUnit(_ componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        audioUnit = try AutoHarpExtensionAudioUnit(componentDescription: componentDescription, options: [])

        guard let audioUnit = self.audioUnit as? AutoHarpExtensionAudioUnit else {
            log.error("Unable to create AutoHarpExtensionAudioUnit")
            return self.audioUnit!
        }

        audioUnit.setupParameterTree(AutoHarpExtensionParameterSpecs.createAUParameterTree())
        DispatchQueue.main.async { self.configureSwiftUIView(audioUnit: audioUnit) }
        return audioUnit
    }
    
    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        if hostingController != nil { return }
        
        guard let observableParameterTree = audioUnit.observableParameterTree else {
            return
        }
        let au = audioUnit as? AutoHarpExtensionAudioUnit
        let content = AutoHarpExtensionMainView(
            parameterTree: observableParameterTree,
            secondsToNextBeat: { au?.kernel.secondsToNextBeat() ?? 0 }
        )
        let host = HostingController(rootView: content)
        self.addChild(host)
        host.view.frame = self.view.bounds
        host.view.backgroundColor = .clear
        self.view.addSubview(host.view)
        hostingController = host
        
        // Make sure the SwiftUI view fills the full area provided by the view controller
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
        host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor).isActive = true
        host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor).isActive = true
        host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true
        self.view.bringSubviewToFront(host.view)
    }
    
}
