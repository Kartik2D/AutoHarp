//
//  AutoHarpExtensionAudioUnit.swift
//  AutoHarpExtension
//
//  Created by Kartik Vinayak on 9/11/26.
//

import AVFoundation

public class AutoHarpExtensionAudioUnit: AUAudioUnit, @unchecked Sendable
{
	// C++ Objects
	var kernel = AutoHarpExtensionDSPKernel()
    var processHelper: AUProcessHelper?

	private var outputBus: AUAudioUnitBus?
	private var _outputBusses: AUAudioUnitBusArray!

	private var format:AVAudioFormat

	@objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
		self.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
		try super.init(componentDescription: componentDescription, options: options)
		outputBus = try AUAudioUnitBus(format: self.format)
        outputBus?.maximumChannelCount = 2
		_outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: AUAudioUnitBusType.output, busses: [outputBus!])
        kernel.initialize(outputBus!.format.sampleRate)
        processHelper = AUProcessHelper(&kernel)
	}

	public override var outputBusses: AUAudioUnitBusArray {
		return _outputBusses
	}
    
    public override var  maximumFramesToRender: AUAudioFrameCount {
        get {
            return kernel.maximumFramesToRender()
        }

        set {
            kernel.setMaximumFramesToRender(newValue)
        }
    }

    public override var  shouldBypassEffect: Bool {
        get {
            return kernel.isBypassed()
        }

        set {
            kernel.setBypass(newValue)
        }
    }

    // MARK: - MIDI
    public override var audioUnitMIDIProtocol: MIDIProtocolID {
        return kernel.AudioUnitMIDIProtocol()
    }

    public override var midiOutputNames: [String] {
        ["MIDI Out"]
    }

    // MARK: - Rendering
    public override var internalRenderBlock: AUInternalRenderBlock {
        return processHelper!.internalRenderBlock()
    }

    // Allocate resources required to render.
    // Subclassers should call the superclass implementation.
    public override func allocateRenderResources() throws {		
        kernel.initialize(outputBus!.format.sampleRate)
        kernel.prepareOutput(outputBus!.format.channelCount, kernel.maximumFramesToRender())
        try super.allocateRenderResources()
        kernel.setMIDI1OutputEventBlock(self.midiOutputEventBlock)
        kernel.setMIDIOutputEventBlock(self.midiOutputEventListBlock)
	}

    // Deallocate resources allocated in allocateRenderResourcesAndReturnError:
    // Subclassers should call the superclass implementation.
    public override func deallocateRenderResources() {
        
        // Deallocate your resources.
        kernel.setMIDI1OutputEventBlock(nil)
        kernel.setMIDIOutputEventBlock(nil)
        kernel.deInitialize()
        
        super.deallocateRenderResources()
    }

	public func setupParameterTree(_ parameterTree: AUParameterTree) {
		self.parameterTree = parameterTree

		// Set the Parameter default values before setting up the parameter callbacks
		for param in parameterTree.allParameters {
            kernel.setParameter(param.address, param.value)
		}

		setupParameterCallbacks()
	}

	private func setupParameterCallbacks() {
		// implementorValueObserver is called when a parameter changes value.
		parameterTree?.implementorValueObserver = { [weak self] param, value -> Void in
            self?.kernel.setParameter(param.address, value)
		}
        Harp.shared.play = { [weak self] on, note in
            if on { self?.kernel.strumVoiceOn(note) } else { self?.kernel.strumVoiceOff(note) }
        }

		// implementorValueProvider is called when the value needs to be refreshed.
		parameterTree?.implementorValueProvider = { [weak self] param in
            return self!.kernel.getParameter(param.address)
		}

		// A function to provide string representations of parameter values.
		parameterTree?.implementorStringFromValueCallback = { param, valuePtr in
			guard let value = valuePtr?.pointee else { return "-" }
			if let names = param.valueStrings {
				let i = Int(value.rounded())
				if names.indices.contains(i) { return names[i] }
			}
			if param.identifier == "metroBPM" { return String(format: "%.0f BPM", value) }
			if param.unit == .milliseconds { return String(format: "%.0f ms", value) }
			if param.identifier.hasSuffix("Sustain") || param.identifier.hasSuffix("Volume") {
				return String(format: "%.0f%%", value * 100)
			}
			return String(format: "%.2f", value)
		}
	}
}
