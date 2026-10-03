//
//  CircleOfFifthsView.swift
//  AutoHarpExtension
//
//  Layout and notes follow https://omnichord.amplib.app/
//

import SwiftUI
import UIKit

struct CircleOfFifthsView: View {
        var noteParam: Knob
        var gateParam: Knob
        var qualityParam: Knob
        var layoutParam: Knob
        var coloringParam: Knob
        var metroOnParam: Knob
        var metroBPMParam: Knob
        var metroSyncParam: Knob
        var pianoEnabled = false
    var retuneChord: () -> Void = {}
    var secondsToNextBeat: () -> TimeInterval = { 0 }
    @Environment(\.harpTheme) private var theme
    @State private var chordOn = false
    @State private var latched = (root: 0, quality: 0)
    @State private var pressed: (root: Int, quality: Int)?
    @State private var pressedLoop: Int?
    @State private var loopHoldTask: Task<Void, Never>?
    @State private var loopHeld = false
    @State private var strumActive = Set<Int>()
    @State private var strumSounding = [Int: UInt8]()
    @State private var strumHit = 0
    @State private var strumAdded = Set<Int>()
    @State private var strumNudge: CGFloat = 1
    @State private var lastStrum: [SpatialEventCollection.Event.ID: CGPoint] = [:]
    @State private var pianoHeld = Set<UInt8>()
    @State private var pianoLive = false
    @State private var loops = LoopSlots()
    @State private var playTask: Task<Void, Never>?
    @State private var beatTask: Task<Void, Never>?
    private var isFifths: Bool { layoutParam.value >= 0.5 }
    private var fifthsColor: Bool { coloringParam.value >= 0.5 }
    private var playingLoop: ChordLooper? { loops.slots.first { $0.isPlaying } }
    private var recorder: ChordLooper? { loops.slots.first { $0.phase == .armed || $0.phase == .recording } }
    private var shouldSnap: Bool { metroSyncParam.value >= 0.5 && metroOnParam.value >= 0.5 }

    private var tint: Color {
        OmnichordChords.page(on: chordOn, pc: latched.root, fifths: fifthsColor, theme: theme)
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let short = min(geo.size.width, geo.size.height)
            let gutter = max(1, short * 0.005)
            let pad = max(16, short * 0.02)
            let inner = CGRect(x: pad, y: pad, width: geo.size.width - pad * 2, height: geo.size.height - pad * 2)
            let boxes = playBoxes(inner: inner, landscape: landscape, fifths: isFifths, alley: pad)
            let pianoRect = boxes.piano
            let chordRect = boxes.chord
            let harpRect = boxes.harp
            let loopRect = boxes.loop
            let radius: CGFloat = 12
            let harpNotes = OmnichordChords.harpNotes(pc: latched.root, quality: latched.quality)
            let harpCount = max(harpNotes.count, 1)
            let layout = FifthsLayout(size: min(chordRect.width, chordRect.height), gutter: gutter)
            ZStack(alignment: .topLeading) {
                PianoStrip(
                    chord: heldChordNotes,
                    strum: Set(strumSounding.values).union(pianoHeld),
                    color: padColor(pc: latched.root, on: chordOn, fifths: fifthsColor, theme: theme)
                )
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
                .frame(width: pianoRect.width, height: pianoRect.height)
                .position(x: pianoRect.midX, y: pianoRect.midY)
                .allowsHitTesting(false)
                if isFifths {
                    FifthsWheel(layout: layout, chordOn: chordOn, latched: latched, fifthsColor: fifthsColor)
                        .frame(width: layout.size, height: layout.size)
                        .position(x: chordRect.midX, y: chordRect.midY)
                } else {
                    ChordGrid(rect: chordRect, landscape: landscape, gutter: gutter, radius: radius, chordOn: chordOn, latched: latched, fifthsColor: fifthsColor)
                }
                StrumPad(
                    count: harpCount,
                    horizontal: landscape,
                    spacing: gutter * 2,
                    color: padColor(pc: latched.root, on: chordOn, fifths: fifthsColor, theme: theme),
                    lit: UIColor(theme.flash),
                    hit: strumHit,
                    added: strumAdded,
                    nudge: strumNudge
                )
                .frame(width: harpRect.width, height: harpRect.height)
                .clipped()
                .position(x: harpRect.midX, y: harpRect.midY)
                .allowsHitTesting(false)
                LoopBank(
                    phases: loops.slots.map(\.phase),
                    spacing: gutter * 2,
                    radius: radius,
                    theme: theme
                )
                .frame(width: loopRect.width, height: loopRect.height)
                .clipped()
                .position(x: loopRect.midX, y: loopRect.midY)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "omni")
            .gesture(
                SpatialEventGesture(coordinateSpace: .named("omni"))
                    .onChanged { events in
                        var next = Set<Int>()
                        var pianoNext = Set<UInt8>()
                        var live: [SpatialEventCollection.Event.ID: CGPoint] = [:]
                        var loopIndex: Int?
                        let active = events.filter { $0.phase == .active }
                        for event in active {
                            if let i = LoopBank.index(event.location, in: loopRect) {
                                loopIndex = i
                            } else if pianoEnabled, let note = PianoStrip.note(event.location, in: pianoRect) {
                                pianoNext.insert(note)
                            } else if let cell = cellAt(event.location, in: chordRect, landscape: landscape, fifths: isFifths, layout: layout) {
                                if pressed?.root != cell.root || pressed?.quality != cell.quality {
                                    pressed = cell
                                    select(root: cell.root, quality: cell.quality)
                                }
                            }
                        }
                        let strings = max(OmnichordChords.harpNotes(pc: latched.root, quality: latched.quality).count, 1)
                        for event in active {
                            guard let i = StrumPad.index(event.location, in: harpRect, horizontal: landscape, count: strings) else { continue }
                            if LoopBank.index(event.location, in: loopRect) != nil { continue }
                            if pianoEnabled, PianoStrip.note(event.location, in: pianoRect) != nil { continue }
                            if cellAt(event.location, in: chordRect, landscape: landscape, fifths: isFifths, layout: layout) != nil { continue }
                            if let last = lastStrum[event.id] {
                                let along = landscape ? event.location.y - last.y : event.location.x - last.x
                                if along != 0 { strumNudge = along > 0 ? 1 : -1 }
                                if let j = StrumPad.index(last, in: harpRect, horizontal: landscape, count: strings) {
                                    for k in min(i, j)...max(i, j) { next.insert(k) }
                                }
                            }
                            live[event.id] = event.location
                            next.insert(i)
                        }
                        if let i = loopIndex {
                            if pressedLoop != i {
                                loopHoldTask?.cancel()
                                pressedLoop = i
                                loopHeld = false
                                loopHoldTask = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(500))
                                    guard !Task.isCancelled, pressedLoop == i else { return }
                                    guard loops.slots[i].phase != .empty else { return }
                                    loopHeld = true
                                    deleteLoop(i)
                                }
                            }
                        } else if pressedLoop != nil {
                            loopHoldTask?.cancel()
                            loopHeld = true
                            pressedLoop = nil
                        }
                        lastStrum = live
                        if !pianoNext.isEmpty { pianoLive = true }
                        if playingLoop == nil || pianoLive { applyPiano(pianoNext) }
                        if playingLoop == nil || !live.isEmpty { applyStrum(chordOn ? next : []) }
                    }
                    .onEnded { _ in
                        let wasStrum = !lastStrum.isEmpty
                        let wasPiano = pianoLive
                        loopHoldTask?.cancel()
                        if let i = pressedLoop, !loopHeld { tapLoop(i) }
                        pressed = nil
                        pressedLoop = nil
                        loopHeld = false
                        lastStrum = [:]
                        pianoLive = false
                        if playingLoop == nil || wasPiano { applyPiano([]) }
                        if playingLoop == nil || wasStrum { applyStrum([]) }
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: pianoEnabled) { _, on in
            if !on { applyPiano([]) }
        }
        .background {
            tint
                .ignoresSafeArea()
                .backgroundExtensionEffect()
        }
    }

    private var heldChordNotes: Set<UInt8> {
        chordOn ? Set(OmnichordChords.padNotes(pc: latched.root, quality: latched.quality)) : []
    }

    private func playBoxes(inner: CGRect, landscape: Bool, fifths: Bool, alley: CGFloat) -> (piano: CGRect, chord: CGRect, loop: CGRect, harp: CGRect) {
        let barH = landscape ? inner.height * 0.11 : min(56, inner.height * 0.07)
        let pianoH = barH
        let loopH = landscape ? barH : min(48, inner.height * 0.055)
        let piano = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: pianoH)
        let loop = CGRect(x: inner.minX, y: inner.maxY - loopH, width: inner.width, height: loopH)
        let midY = piano.maxY + alley
        let midH = max(0, loop.minY - alley - midY)
        if landscape {
            let harpW = fifths
                ? max(inner.width * 0.16, inner.width - min(midH, inner.width) - alley)
                : inner.width * 0.11
            let chord = CGRect(x: inner.minX, y: midY, width: max(0, inner.width - harpW - alley), height: midH)
            let harp = CGRect(x: chord.maxX + alley, y: midY, width: max(0, inner.maxX - chord.maxX - alley), height: midH)
            return (piano, chord, loop, harp)
        }
        let harpMin = inner.height * 0.18
        let chordH = min(inner.width, max(0, midH - harpMin - alley))
        let chord = CGRect(x: inner.minX, y: midY, width: inner.width, height: chordH)
        let harpY = chord.maxY + alley
        let harp = CGRect(x: inner.minX, y: harpY, width: inner.width, height: max(0, loop.minY - alley - harpY))
        return (piano, chord, loop, harp)
    }

    private func cellAt(_ point: CGPoint, in rect: CGRect, landscape: Bool, fifths: Bool, layout: FifthsLayout) -> (root: Int, quality: Int)? {
        if fifths { return layout.slice(point, center: CGPoint(x: rect.midX, y: rect.midY)) }
        guard rect.contains(point) else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        let qualities = OmnichordChords.qualityCount
        if landscape {
            return (min(11, Int(x * 12)), min(qualities - 1, Int(y * CGFloat(qualities))))
        }
        return (min(11, Int(y * 12)), min(qualities - 1, Int(x * CGFloat(qualities))))
    }

    private func applyStrum(_ next: Set<Int>) {
        let table = OmnichordChords.harpNotes(pc: latched.root, quality: latched.quality)
        var nextSounding: [Int: UInt8] = [:]
        for i in next where table.indices.contains(i) { nextSounding[i] = table[i] }
        for (i, note) in strumSounding where nextSounding[i] != note { Harp.shared.release(note) }
        var added = Set<Int>()
        for (i, note) in nextSounding where strumSounding[i] != note {
            Harp.shared.pluck(note)
            added.insert(i)
        }
        strumActive = next
        strumSounding = nextSounding
        if !added.isEmpty {
            strumAdded = added
            strumHit += 1
        }
        recorder?.noteStrum(next)
    }

    // ponytail: Harp has no refcount; same MIDI from pad+piano can cut the other
    private func applyPiano(_ next: Set<UInt8>) {
        for note in pianoHeld where !next.contains(note) { Harp.shared.release(note) }
        for note in next where !pianoHeld.contains(note) { Harp.shared.pluck(note) }
        pianoHeld = next
        recorder?.notePiano(next)
    }

    private func select(root: Int, quality: Int) {
        if playingLoop != nil { stopPlayingLoop() }
        if chordOn && latched.root == root && latched.quality == quality {
            setChord(root: root, quality: quality, on: false)
        } else {
            setChord(root: root, quality: quality, on: true)
        }
        recorder?.noteChord(root: root, quality: quality, on: chordOn)
    }

    private func setChord(root: Int, quality: Int, on: Bool) {
        if on {
            latched = (root, quality)
            chordOn = true
            qualityParam.value = AUValue(quality)
            noteParam.value = AUValue(48 + root)
            retuneChord()
            gateParam.value = 1
            if !strumActive.isEmpty { applyStrum(strumActive) }
        } else {
            chordOn = false
            gateParam.value = 0
            applyStrum([])
        }
    }

    private func cancelBeatWait() {
        beatTask?.cancel()
        beatTask = nil
    }

    private func stopPlayingLoop() {
        cancelBeatWait()
        playTask?.cancel()
        playTask = nil
        playingLoop?.stopKeepingTake()
        clearQueue()
        applyStrum([])
        applyPiano([])
    }

    private func clearQueue() {
        for slot in loops.slots where slot.phase == .queued { slot.stopKeepingTake() }
    }

    private func deleteLoop(_ i: Int) {
        let slot = loops.slots[i]
        guard slot.phase != .empty else { return }
        if slot.isPlaying {
            cancelBeatWait()
            playTask?.cancel()
            playTask = nil
            clearQueue()
        } else if slot.phase == .queued {
            cancelBeatWait()
        }
        slot.clear()
    }

    private func tapLoop(_ i: Int) {
        let slot = loops.slots[i]
        switch slot.phase {
        case .empty:
            stopOthers(except: i)
            if chordOn { setChord(root: latched.root, quality: latched.quality, on: false) }
            slot.arm()
        case .armed:
            cancelBeatWait()
            slot.clear()
        case .recording:
            loops.slots[i].close(beat: shouldSnap ? beatPeriod() : 0)
            startPlayback(i, snap: false)
        case .playing:
            stopPlayingLoop()
        case .queued:
            startPlayback(i)
        case .stopped:
            if playingLoop != nil {
                clearQueue()
                slot.queue()
            } else {
                startPlayback(i)
            }
        }
    }

    private func stopOthers(except keep: Int) {
        cancelBeatWait()
        playTask?.cancel()
        playTask = nil
        for (j, slot) in loops.slots.enumerated() where j != keep {
            if slot.isPlaying || slot.phase == .queued { slot.stopKeepingTake() }
            else if slot.phase == .armed || slot.phase == .recording { slot.clear() }
        }
    }

    private func beatPeriod() -> TimeInterval {
        60 / max(1, Double(metroBPMParam.value))
    }

    private func nextBeatWait() -> TimeInterval {
        guard shouldSnap else { return 0 }
        return max(0, secondsToNextBeat())
    }

    private func startPlayback(_ i: Int, snap: Bool = true) {
        if snap {
            let wait = nextBeatWait()
            if wait > 0 {
                clearQueue()
                loops.slots[i].queue()
                beatTask?.cancel()
                beatTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    guard !Task.isCancelled, loops.slots[i].phase == .queued else { return }
                    startPlayback(i, snap: false)
                }
                return
            }
        }
        cancelBeatWait()
        playTask?.cancel()
        for (j, slot) in loops.slots.enumerated() where j != i {
            if slot.isPlaying || slot.phase == .queued { slot.stopKeepingTake() }
        }
        let slot = loops.slots[i]
        slot.resume()
        slot.isReplaying = true
        let events = slot.events
        let duration = slot.duration
        playTask = Task { @MainActor in
            defer { slot.isReplaying = false }
            while !Task.isCancelled, slot.isPlaying {
                applyStrum([])
                applyPiano([])
                let cycleStart = CACurrentMediaTime()
                for event in events {
                    let wait = event.t - (CACurrentMediaTime() - cycleStart)
                    if wait > 0 {
                        do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    }
                    guard !Task.isCancelled, slot.isPlaying else { return }
                    play(event)
                }
                let remaining = duration - (CACurrentMediaTime() - cycleStart)
                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                }
                guard !Task.isCancelled, slot.isPlaying else { return }
                if let next = loops.slots.firstIndex(where: { $0.phase == .queued }) {
                    slot.stopKeepingTake()
                    startPlayback(next, snap: false)
                    return
                }
            }
        }
    }

    private func play(_ event: ChordLooper.Event) {
        switch event.kind {
        case .chord(let root, let quality, let on):
            setChord(root: root, quality: quality, on: on)
        case .strum(let pads):
            applyStrum(pads)
        case .piano(let notes):
            applyPiano(notes)
        }
    }
}

private func isBlackKey(_ note: Int) -> Bool {
    switch ((note % 12) + 12) % 12 {
    case 1, 3, 6, 8, 10: return true
    default: return false
    }
}

private struct PianoStrip: View {
    var chord: Set<UInt8>
    var strum: Set<UInt8>
    var color: UIColor
    var low: UInt8 = 36
    var high: UInt8 = 96
    @Environment(\.harpTheme) private var theme

    static func note(_ point: CGPoint, in rect: CGRect, low: UInt8 = 36, high: UInt8 = 96) -> UInt8? {
        guard rect.contains(point) else { return nil }
        let whites = (Int(low)...Int(high)).filter { !isBlackKey($0) }
        guard !whites.isEmpty else { return nil }
        let w = rect.width / CGFloat(whites.count)
        let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        let bw = w * 0.58
        let bh = rect.height * 0.62
        if local.y <= bh {
            for n in Int(low)...Int(high) where isBlackKey(n) {
                guard let left = whites.firstIndex(of: n - 1) else { continue }
                let key = CGRect(x: CGFloat(left + 1) * w - bw / 2, y: 0, width: bw, height: bh)
                if key.contains(local) { return UInt8(n) }
            }
        }
        return UInt8(whites[min(whites.count - 1, max(0, Int(local.x / w)))])
    }

    var body: some View {
        Canvas { context, size in
            let whites = (Int(low)...Int(high)).filter { !isBlackKey($0) }
            let w = size.width / CGFloat(max(whites.count, 1))
            let gap: CGFloat = 1
            let idle = chord.isEmpty
            for (i, note) in whites.enumerated() {
                let rect = CGRect(x: CGFloat(i) * w + gap / 2, y: 0, width: max(1, w - gap), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill(note, black: false, idle: idle)))
            }
            let bw = w * 0.58
            let bh = size.height * 0.62
            for note in Int(low)...Int(high) where isBlackKey(note) {
                guard let left = whites.firstIndex(of: note - 1) else { continue }
                let rect = CGRect(x: CGFloat(left + 1) * w - bw / 2, y: 0, width: bw, height: bh)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(fill(note, black: true, idle: idle)))
            }
        }
    }

    private func fill(_ note: Int, black: Bool, idle: Bool) -> Color {
        let n = UInt8(note)
        if strum.contains(n) { return theme.flash }
        if chord.contains(n) { return Color(color) }
        if idle || theme.isLight { return OmnichordChords.piano(black: black, theme: theme) }
        return black ? tone(0.32) : tone(0.55)
    }

    private func tone(_ factor: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(b) * Double(factor), opacity: Double(a))
    }
}

private func padColor(pc: Int, lit: Bool = false, on: Bool = true, fifths: Bool = false, theme: HarpTheme) -> UIColor {
    if !on { return UIColor(OmnichordChords.idlePad(theme: theme)) }
    if lit { return .white }
    return UIColor(OmnichordChords.color(pc: pc, fifths: fifths, theme: theme))
}

private struct LoopBank: UIViewRepresentable {
    var phases: [ChordLooper.Phase]
    var spacing: CGFloat
    var radius: CGFloat
    var theme: HarpTheme

    static func index(_ point: CGPoint, in rect: CGRect, count: Int = 5) -> Int? {
        guard rect.contains(point), count > 0 else { return nil }
        let vertical = rect.height >= rect.width
        let t = vertical ? (point.y - rect.minY) / rect.height : (point.x - rect.minX) / rect.width
        return min(count - 1, max(0, Int(t * CGFloat(count))))
    }

    func makeUIView(context: Context) -> LoopBankView {
        let view = LoopBankView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: LoopBankView, context: Context) {
        view.apply(phases: phases, spacing: spacing, radius: radius, theme: theme)
    }
}

private final class LoopBankView: UIView {
    private var pads: [CAShapeLayer] = []
    private var icons: [CALayer] = []
    private var records: [CAShapeLayer] = []
    private var phases: [ChordLooper.Phase] = []
    private var spacing: CGFloat = 4
    private var radius: CGFloat = 12
    private var theme = HarpTheme.classic

    override func layoutSubviews() {
        super.layoutSubviews()
        sync()
    }

    func apply(phases: [ChordLooper.Phase], spacing: CGFloat, radius: CGFloat, theme: HarpTheme) {
        self.phases = phases
        self.spacing = spacing
        self.radius = radius
        self.theme = theme
        sync()
    }

    private func sync() {
        let count = 5
        while pads.count < count {
            let pad = CAShapeLayer()
            layer.addSublayer(pad)
            pads.append(pad)
            let icon = CALayer()
            icon.contentsGravity = .resizeAspect
            icon.contentsScale = UIScreen.main.scale
            layer.addSublayer(icon)
            icons.append(icon)
            let record = CAShapeLayer()
            record.fillColor = UIColor.red.cgColor
            layer.addSublayer(record)
            records.append(record)
        }
        guard bounds.width > 1, bounds.height > 1 else { return }
        let vertical = bounds.height >= bounds.width
        for i in 0..<count {
            let rect = cell(i, count: count, vertical: vertical)
            pads[i].path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
            let phase = phases.indices.contains(i) ? phases[i] : .empty
            let loaded = phase == .stopped || phase == .queued || phase == .playing || phase == .recording
            pads[i].fillColor = UIColor(OmnichordChords.loopPad(slot: i, loaded: loaded, theme: theme)).cgColor
            let iconSize = max(12, min(rect.width, rect.height) * 0.38)
            let iconRect = CGRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
            icons[i].frame = iconRect
            records[i].path = CGPath(ellipseIn: iconRect, transform: nil)
            let blinkLayer: CALayer?
            switch phase {
            case .armed:
                icons[i].contents = symbol("ellipsis", size: iconSize)
                icons[i].isHidden = false
                records[i].isHidden = true
                blinkLayer = icons[i]
            case .recording:
                icons[i].contents = nil
                icons[i].isHidden = true
                records[i].isHidden = false
                blinkLayer = records[i]
            case .stopped:
                icons[i].contents = symbol("play.fill", size: iconSize)
                icons[i].isHidden = false
                records[i].isHidden = true
                blinkLayer = nil
            case .queued:
                icons[i].contents = symbol("play.fill", size: iconSize)
                icons[i].isHidden = false
                records[i].isHidden = true
                blinkLayer = icons[i]
            case .playing:
                icons[i].contents = symbol("pause.fill", size: iconSize)
                icons[i].isHidden = false
                records[i].isHidden = true
                blinkLayer = icons[i]
            default:
                icons[i].contents = nil
                icons[i].isHidden = true
                records[i].isHidden = true
                blinkLayer = nil
            }
            flash(icons[i], on: blinkLayer === icons[i])
            flash(records[i], on: blinkLayer === records[i])
        }
    }

    private func flash(_ layer: CALayer, on: Bool) {
        if on {
            if layer.animation(forKey: "blink") == nil {
                let flash = CAKeyframeAnimation(keyPath: "opacity")
                flash.values = [1, 1, 0, 0]
                flash.keyTimes = [0, 0.5, 0.5, 1]
                flash.duration = 0.6
                flash.calculationMode = .discrete
                flash.repeatCount = .infinity
                layer.add(flash, forKey: "blink")
            }
        } else {
            layer.removeAnimation(forKey: "blink")
            layer.opacity = 1
        }
    }

    private func symbol(_ name: String, size: CGFloat) -> CGImage? {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(UIColor(theme.ink), renderingMode: .alwaysOriginal)
            .cgImage
    }

    private func cell(_ i: Int, count: Int, vertical: Bool) -> CGRect {
        if vertical {
            let h = (bounds.height - CGFloat(count - 1) * spacing) / CGFloat(count)
            return CGRect(x: 0, y: CGFloat(i) * (h + spacing), width: bounds.width, height: h)
        }
        let w = (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count)
        return CGRect(x: CGFloat(i) * (w + spacing), y: 0, width: w, height: bounds.height)
    }
}

private struct PadLayers: UIViewRepresentable {
    var fills: [(CGPath, UIColor)]
    var strokes: [CGPath] = []
    var stroke: UIColor = UIColor.white.withAlphaComponent(0.35)

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (path, color) in fills {
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = color.cgColor
            layer.fillRule = .evenOdd
            view.layer.addSublayer(layer)
        }
        for path in strokes {
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = stroke.cgColor
            layer.lineWidth = 1
            view.layer.addSublayer(layer)
        }
    }
}

private struct ChordGrid: View {
    let rect: CGRect
    let landscape: Bool
    let gutter: CGFloat
    let radius: CGFloat
    let chordOn: Bool
    let latched: (root: Int, quality: Int)
    let fifthsColor: Bool
    @Environment(\.harpTheme) private var theme

    var body: some View {
        let gap = gutter * 2
        let outer = landscape ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
        let inner = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        ZStack {
            PadLayers(fills: stripFills(size: rect.size, landscape: landscape, gap: gap, radius: radius))
            outer {
                ForEach(0..<12, id: \.self) { root in
                    inner {
                        ForEach(0..<OmnichordChords.qualityCount, id: \.self) { quality in
                            if quality > 0 {
                                Divider()
                                    .overlay(theme.ink)
                                    .padding(landscape ? .horizontal : .vertical, 8)
                            }
                            let on = chordOn && latched.root == root && latched.quality == quality
                            Text(OmnichordChords.label(root: root, quality: quality))
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .minimumScaleFactor(0.4)
                                .lineLimit(1)
                                .foregroundStyle(on ? Color.black : theme.ink)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background { if on { Color.white } }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    private func stripFills(size: CGSize, landscape: Bool, gap: CGFloat, radius: CGFloat) -> [(CGPath, UIColor)] {
        (0..<12).map { i in
            let r: CGRect
            if landscape {
                let w = (size.width - 11 * gap) / 12
                r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
            } else {
                let h = (size.height - 11 * gap) / 12
                r = CGRect(x: 0, y: CGFloat(i) * (h + gap), width: size.width, height: h)
            }
            return (UIBezierPath(roundedRect: r, cornerRadius: radius).cgPath, padColor(pc: i, fifths: fifthsColor, theme: theme))
        }
    }
}

private struct FifthsWheel: View {
    let layout: FifthsLayout
    let chordOn: Bool
    let latched: (root: Int, quality: Int)
    let fifthsColor: Bool
    @Environment(\.harpTheme) private var theme

    var body: some View {
        ZStack {
            PadLayers(fills: pads())
                .frame(width: layout.size, height: layout.size)
            ForEach(0..<3, id: \.self) { ring in
                ForEach(0..<12, id: \.self) { slice in
                    let chord = OmnichordChords.fifthsChord(slice: slice, ring: ring)
                    let on = chordOn && latched.root == chord.root && latched.quality == chord.quality
                    FifthsLabel(item: layout.item(ring: ring, slice: slice), selected: on)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func pads() -> [(CGPath, UIColor)] {
        (0..<3).flatMap { ring in
            (0..<12).map { slice in
                let chord = OmnichordChords.fifthsChord(slice: slice, ring: ring)
                let lit = chordOn && latched.root == chord.root && latched.quality == chord.quality
                return (layout.pad(ring: ring, slice: slice), padColor(pc: chord.root, lit: lit, fifths: fifthsColor, theme: theme))
            }
        }
    }
}

private struct FifthsLabel: View {
    let item: FifthsItem
    var selected = false
    @Environment(\.harpTheme) private var theme

    var body: some View {
        Text(item.label)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .foregroundStyle(selected ? Color.black : theme.ink)
            .frame(width: item.labelSize, height: item.labelSize)
            .position(item.labelCenter)
    }
}

private struct FifthsItem {
    let label: String
    let labelSize: CGFloat
    let labelCenter: CGPoint
}

private struct FifthsLayout {
    let size: CGFloat
    let gap: CGFloat
    let hole: CGFloat
    let ringW: CGFloat

    init(size: CGFloat, gutter: CGFloat) {
        self.size = size
        gap = max(1, gutter * 2)
        let outer = size / 2
        hole = max(outer * 0.16, gap * 4)
        ringW = max(1, (outer - hole) / 3)
    }

    func band(_ ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        let outer = size / 2 - CGFloat(ring) * ringW
        return (outer - ringW, outer)
    }

    func pad(ring: Int, slice: Int) -> CGPath {
        let r = band(ring)
        let mid = max(1, (r.inner + r.outer) / 2)
        let padA = gap / (2 * mid)
        let start = CGFloat(slice) * .pi / 6 - .pi / 2 - .pi / 12 + padA
        let end = start + .pi / 6 - 2 * padA
        let inner = r.inner + gap / 2
        let outer = r.outer - gap / 2
        let c = CGPoint(x: size / 2, y: size / 2)
        func polar(_ rad: CGFloat, _ a: CGFloat) -> CGPoint {
            CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
        }
        func heading(_ from: CGPoint, _ to: CGPoint) -> CGFloat {
            atan2(to.y - from.y, to.x - from.x)
        }
        let cr = min(12, (outer - inner) * 0.35, (end - start) * inner * 0.35)
        let p = CGMutablePath()
        guard cr > 1, outer > inner + 2 * cr else {
            p.addArc(center: c, radius: outer, startAngle: start, endAngle: end, clockwise: false)
            p.addArc(center: c, radius: inner, startAngle: end, endAngle: start, clockwise: true)
            p.closeSubpath()
            return p
        }
        let dOut = asin(min(1, cr / max(outer - cr, 1)))
        let dIn = asin(min(1, cr / max(inner + cr, 1)))
        let fos = polar(outer - cr, start + dOut)
        let foe = polar(outer - cr, end - dOut)
        let fie = polar(inner + cr, end - dIn)
        let fis = polar(inner + cr, start + dIn)
        let pOS = polar(outer - cr, start)
        let qOS = polar(outer, start + dOut)
        let qOE = polar(outer, end - dOut)
        let pOE = polar(outer - cr, end)
        let pIE = polar(inner + cr, end)
        let qIE = polar(inner, end - dIn)
        let qIS = polar(inner, start + dIn)
        let pIS = polar(inner + cr, start)
        p.move(to: pIS)
        p.addLine(to: pOS)
        p.addArc(center: fos, radius: cr, startAngle: heading(fos, pOS), endAngle: heading(fos, qOS), clockwise: false)
        p.addArc(center: c, radius: outer, startAngle: start + dOut, endAngle: end - dOut, clockwise: false)
        p.addArc(center: foe, radius: cr, startAngle: heading(foe, qOE), endAngle: heading(foe, pOE), clockwise: false)
        p.addLine(to: pIE)
        p.addArc(center: fie, radius: cr, startAngle: heading(fie, pIE), endAngle: heading(fie, qIE), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: end - dIn, endAngle: start + dIn, clockwise: true)
        p.addArc(center: fis, radius: cr, startAngle: heading(fis, qIS), endAngle: heading(fis, pIS), clockwise: false)
        p.closeSubpath()
        return p
    }

    func item(ring: Int, slice: Int) -> FifthsItem {
        let r = band(ring)
        let mid = (r.inner + r.outer) / 2
        let c = size / 2
        let angle = Double(slice) * .pi / 6 - .pi / 2
        let chord = OmnichordChords.fifthsChord(slice: slice, ring: ring)
        let h = max(1, r.outer - r.inner - gap)
        let w = max(1, mid * .pi / 6 - gap)
        return FifthsItem(
            label: OmnichordChords.label(root: chord.root, quality: chord.quality),
            labelSize: min(h, w),
            labelCenter: CGPoint(x: c + CGFloat(cos(angle)) * mid, y: c + CGFloat(sin(angle)) * mid)
        )
    }

    func item(root: Int, quality: Int) -> FifthsItem? {
        for ring in 0..<3 {
            for slice in 0..<12 {
                let chord = OmnichordChords.fifthsChord(slice: slice, ring: ring)
                if chord.root == root && chord.quality == quality {
                    return item(ring: ring, slice: slice)
                }
            }
        }
        return nil
    }

    func slice(_ point: CGPoint, center: CGPoint) -> (root: Int, quality: Int)? {
        let dist = hypot(point.x - center.x, point.y - center.y)
        guard let ring = (0..<3).first(where: {
            let b = band($0)
            return dist <= b.outer && dist >= b.inner
        }) else { return nil }
        var a = atan2(point.y - center.y, point.x - center.x) + .pi / 2 + .pi / 12
        if a < 0 { a += 2 * .pi }
        return OmnichordChords.fifthsChord(slice: min(11, Int(a / (.pi / 6))), ring: ring)
    }
}

private struct StrumPad: UIViewRepresentable {
    var count: Int
    var horizontal: Bool
    var spacing: CGFloat
    var color: UIColor
    var lit: UIColor
    var hit: Int
    var added: Set<Int>
    var nudge: CGFloat

    static func index(_ point: CGPoint, in rect: CGRect, horizontal: Bool, count: Int) -> Int? {
        guard rect.contains(point), count > 0 else { return nil }
        let t = horizontal ? (point.y - rect.minY) / rect.height : 1 - (point.x - rect.minX) / rect.width
        return min(count - 1, max(0, Int(t * CGFloat(count))))
    }

    func makeUIView(context: Context) -> StrumView { StrumView() }

    func updateUIView(_ view: StrumView, context: Context) {
        view.apply(count: count, horizontal: horizontal, spacing: spacing, color: color, lit: lit, hit: hit, added: added, nudge: nudge)
    }
}

private final class StrumView: UIView {
    private var count = 0
    private var horizontal = true
    private var spacing: CGFloat = 4
    private var color = UIColor.white
    private var lit = UIColor.white
    private var nudge: CGFloat = 1
    private var hit = 0
    private var pending = Set<Int>()
    private var strokes: [CAShapeLayer] = []
    private var laidSize: CGSize = .zero
    private var laidCount = 0
    private var laidHorizontal = true

    override func layoutSubviews() {
        super.layoutSubviews()
        sync()
        flush()
    }

    func apply(count: Int, horizontal: Bool, spacing: CGFloat, color: UIColor, lit: UIColor, hit: Int, added: Set<Int>, nudge: CGFloat) {
        self.count = count
        self.horizontal = horizontal
        self.spacing = spacing
        self.color = color
        self.lit = lit
        self.nudge = nudge
        if hit != self.hit {
            self.hit = hit
            pending = added
        }
        sync()
        flush()
    }

    private func sync() {
        guard bounds.width > 1, bounds.height > 1, count > 0 else { return }
        let layoutChanged = laidSize != bounds.size || laidCount != count || laidHorizontal != horizontal
        laidSize = bounds.size
        laidCount = count
        laidHorizontal = horizontal
        while strokes.count < count {
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.lineWidth = 3
            self.layer.addSublayer(layer)
            strokes.append(layer)
        }
        while strokes.count > count {
            strokes.removeLast().removeFromSuperlayer()
        }
        for i in 0..<count {
            let layer = strokes[i]
            let rect = cell(i)
            if layoutChanged {
                layer.removeAnimation(forKey: "vib")
                layer.removeAnimation(forKey: "fade")
            }
            guard rect.width > 1, rect.height > 1 else {
                layer.removeAllAnimations()
                layer.path = nil
                continue
            }
            if layer.animation(forKey: "vib") == nil {
                layer.path = wave(in: rect, amplitude: 0)
            }
            layer.strokeColor = color.cgColor
        }
    }

    private func flush() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        for i in pending where i < strokes.count {
            let rect = cell(i)
            guard rect.width > 1, rect.height > 1 else { continue }
            pluck(strokes[i], in: rect)
        }
        pending = []
    }

    private func pluck(_ layer: CAShapeLayer, in rect: CGRect) {
        let amp = max(5, min(rect.width, rect.height) * 0.2) * nudge
        let steps: [CGFloat] = [1, -1, 0.7, -0.7, 0.35, -0.35, 0]
        let vib = CAKeyframeAnimation(keyPath: "path")
        vib.values = steps.map { wave(in: rect, amplitude: amp * $0) }
        vib.duration = 0.14
        layer.add(vib, forKey: "vib")
        layer.path = wave(in: rect, amplitude: 0)
        let fade = CABasicAnimation(keyPath: "strokeColor")
        fade.fromValue = lit.cgColor
        fade.toValue = color.cgColor
        fade.duration = 0.14
        layer.add(fade, forKey: "fade")
        layer.strokeColor = color.cgColor
    }

    private func cell(_ i: Int) -> CGRect {
        if horizontal {
            let h = (bounds.height - CGFloat(max(count - 1, 0)) * spacing) / CGFloat(count)
            return CGRect(x: 0, y: CGFloat(i) * (h + spacing), width: bounds.width, height: h)
        }
        let w = (bounds.width - CGFloat(max(count - 1, 0)) * spacing) / CGFloat(count)
        return CGRect(x: CGFloat(count - 1 - i) * (w + spacing), y: 0, width: w, height: bounds.height)
    }

    private func wave(in rect: CGRect, amplitude: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if horizontal {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY + amplitude))
        } else {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.midX + amplitude, y: rect.midY))
        }
        return path
    }
}
