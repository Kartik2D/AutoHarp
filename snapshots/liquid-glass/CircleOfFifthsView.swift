//
//  CircleOfFifthsView.swift
//  AutoHarpExtension
//
//  Layout and notes follow https://omnichord.amplib.app/
//

import SwiftUI

struct CircleOfFifthsView: View {
    @State var noteParam: ObservableAUParameter
    @State var gateParam: ObservableAUParameter
    @State var qualityParam: ObservableAUParameter
    @State var strumNoteParam: ObservableAUParameter
    @State var strumGateParam: ObservableAUParameter
    @State var layoutParam: ObservableAUParameter
    @State private var chordOn = false
    @State private var latched = (root: 0, quality: 0)
    @State private var pressed: (root: Int, quality: Int)?
    @State private var strumActive = Set<Int>()
    private var isFifths: Bool { layoutParam.value >= 0.5 }

    private var tint: Color {
        chordOn
            ? OmnichordChords.color(pc: latched.root, brightness: OmnichordChords.baseValue * OmnichordChords.darkFactor)
            : OmnichordChords.neutral(brightness: OmnichordChords.baseValue * 0.7 * OmnichordChords.darkFactor)
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let gutter = max(1, min(geo.size.width, geo.size.height) * 0.005)
            let margin = gutter * 12
            let inner = CGRect(
                x: margin,
                y: margin,
                width: geo.size.width - margin * 2,
                height: geo.size.height - margin * 2
            )
            let alley = gutter * 20
            let harpSpan = landscape ? inner.width * 0.2 : inner.height * 0.2
            let chordRect = landscape
                ? CGRect(x: inner.minX, y: inner.minY, width: inner.width - harpSpan - alley, height: inner.height)
                : CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height - harpSpan - alley)
            let harpRect = (landscape
                ? CGRect(x: chordRect.maxX + alley, y: inner.minY, width: harpSpan, height: inner.height)
                : CGRect(x: inner.minX, y: chordRect.maxY + alley, width: inner.width, height: harpSpan)
            ).insetBy(dx: gutter, dy: gutter)
            let radius: CGFloat = 12
            let harpPitches = OmnichordChords.harpNotes(pc: latched.root, quality: latched.quality).map(AUValue.init)
            let layout = FifthsLayout(size: min(chordRect.width, chordRect.height), gutter: gutter)

            let glow = OmnichordChords.color(pc: latched.root, brightness: OmnichordChords.litValue)
            let harpCount = chordOn ? max(harpPitches.count, 1) : 1
            ZStack(alignment: .topLeading) {
                if chordOn {
                    SelectGlow(
                        fill: glow,
                        fifths: isFifths,
                        layout: layout,
                        chordRect: chordRect,
                        landscape: landscape,
                        gutter: gutter,
                        latched: latched
                    )
                }
                ForEach(strumActive.sorted(), id: \.self) { i in
                    let cell = stringRect(i, in: harpRect, horizontal: landscape, count: harpCount, spacing: gutter * 2)
                    PointGlow(fill: glow, center: CGPoint(x: cell.midX, y: cell.midY), radius: max(cell.width, cell.height) * 1.2)
                }
                if isFifths {
                    FifthsWheel(layout: layout)
                        .frame(width: layout.size, height: layout.size)
                        .position(x: chordRect.midX, y: chordRect.midY)
                } else {
                    ChordGrid(rect: chordRect, landscape: landscape, gutter: gutter, radius: radius)
                }
                StrumPad(
                    pitches: harpPitches,
                    chordOn: chordOn,
                    horizontal: landscape,
                    spacing: gutter * 2,
                    radius: radius
                )
                .frame(width: harpRect.width, height: harpRect.height)
                .position(x: harpRect.midX, y: harpRect.midY)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "omni")
            .simultaneousGesture(
                SpatialEventGesture(coordinateSpace: .named("omni"))
                    .onChanged { events in
                        var next = Set<Int>()
                        let count = max(harpPitches.count, 1)
                        for event in events where event.phase == .active {
                            if let cell = cellAt(event.location, in: chordRect, landscape: landscape, fifths: isFifths, layout: layout) {
                                if pressed?.root != cell.root || pressed?.quality != cell.quality {
                                    pressed = cell
                                    select(root: cell.root, quality: cell.quality)
                                }
                            } else if let i = stringAt(event.location, in: harpRect, horizontal: landscape, count: count) {
                                next.insert(i)
                            }
                        }
                        applyStrum(chordOn ? next : [])
                    }
                    .onEnded { _ in
                        pressed = nil
                        applyStrum([])
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .background {
            tint
                .ignoresSafeArea()
                .backgroundExtensionEffect()
        }
    }

    private func cellAt(_ point: CGPoint, in rect: CGRect, landscape: Bool, fifths: Bool, layout: FifthsLayout) -> (root: Int, quality: Int)? {
        if fifths { return layout.slice(point, center: CGPoint(x: rect.midX, y: rect.midY)) }
        guard rect.contains(point) else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        if landscape {
            return (min(11, Int(x * 12)), min(6, Int(y * 7)))
        }
        return (min(11, Int(y * 12)), min(6, Int(x * 7)))
    }

    private func stringRect(_ i: Int, in rect: CGRect, horizontal: Bool, count: Int, spacing: CGFloat) -> CGRect {
        if horizontal {
            let h = (rect.height - CGFloat(max(count - 1, 0)) * spacing) / CGFloat(count)
            return CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * (h + spacing), width: rect.width, height: h)
        }
        let w = (rect.width - CGFloat(max(count - 1, 0)) * spacing) / CGFloat(count)
        return CGRect(x: rect.minX + CGFloat(count - 1 - i) * (w + spacing), y: rect.minY, width: w, height: rect.height)
    }

    private func stringAt(_ point: CGPoint, in rect: CGRect, horizontal: Bool, count: Int) -> Int? {
        guard rect.contains(point) else { return nil }
        let t = horizontal ? (point.y - rect.minY) / rect.height : 1 - (point.x - rect.minX) / rect.width
        return min(count - 1, max(0, Int(t * CGFloat(count))))
    }

    private func applyStrum(_ next: Set<Int>) {
        guard next != strumActive else { return }
        strumActive = next
        let pitches = OmnichordChords.harpNotes(pc: latched.root, quality: latched.quality)
        let notes = next.compactMap { pitches.indices.contains($0) ? UInt8(min(127, max(0, pitches[$0]))) : nil }
        WheelMIDI.shared.setStrum(Set(notes))
    }

    private func select(root: Int, quality: Int) {
        if chordOn && latched.root == root && latched.quality == quality {
            chordOn = false
            gateParam.value = 0
            applyStrum([])
        } else {
            latched = (root, quality)
            chordOn = true
            qualityParam.value = AUValue(quality)
            noteParam.value = AUValue(48 + root)
            gateParam.value = 1
        }
    }
}

private struct PointGlow: View {
    let fill: Color
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: fill, location: 0),
                    .init(color: fill.opacity(0.28), location: 0.14),
                    .init(color: fill.opacity(0.1), location: 0.4),
                    .init(color: fill.opacity(0), location: 1)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: radius
            ))
            .frame(width: radius * 2, height: radius * 2)
            .blendMode(.plusLighter)
            .position(center)
            .allowsHitTesting(false)
    }
}

private struct SelectGlow: View {
    let fill: Color
    let fifths: Bool
    let layout: FifthsLayout
    let chordRect: CGRect
    let landscape: Bool
    let gutter: CGFloat
    let latched: (root: Int, quality: Int)

    var body: some View {
        if fifths, let item = layout.item(root: latched.root, quality: latched.quality) {
            PointGlow(
                fill: fill,
                center: CGPoint(
                    x: chordRect.midX - layout.size / 2 + item.labelCenter.x,
                    y: chordRect.midY - layout.size / 2 + item.labelCenter.y
                ),
                radius: item.labelSize * 1.15
            )
        } else if let cell = gridCell() {
            PointGlow(fill: fill, center: CGPoint(x: cell.midX, y: cell.midY), radius: max(cell.width, cell.height) * 1.15)
        }
    }

    private func gridCell() -> CGRect? {
        guard !fifths else { return nil }
        let gap = gutter * 2
        if landscape {
            let colW = (chordRect.width - 11 * gap) / 12
            let rowH = chordRect.height / 7
            return CGRect(
                x: chordRect.minX + CGFloat(latched.root) * (colW + gap),
                y: chordRect.minY + CGFloat(latched.quality) * rowH,
                width: colW,
                height: rowH
            )
        }
        let rowH = (chordRect.height - 11 * gap) / 12
        let colW = chordRect.width / 7
        return CGRect(
            x: chordRect.minX + CGFloat(latched.quality) * colW,
            y: chordRect.minY + CGFloat(latched.root) * (rowH + gap),
            width: colW,
            height: rowH
        )
    }
}

private struct ChordGrid: View {
    let rect: CGRect
    let landscape: Bool
    let gutter: CGFloat
    let radius: CGFloat
    @Namespace private var glass

    var body: some View {
        let gap = gutter * 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let outer = landscape ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
        let inner = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return GlassEffectContainer(spacing: 0) {
            outer {
                ForEach(0..<12, id: \.self) { root in
                    inner {
                        ForEach(0..<7, id: \.self) { quality in
                            if quality > 0 { Divider().padding(landscape ? .horizontal : .vertical, 8) }
                            Text(OmnichordChords.label(root: root, quality: quality))
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .minimumScaleFactor(0.4)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipShape(shape)
                    .contentShape(.interaction, shape)
                    .glassEffect(.clear.interactive(), in: shape)
                    .glassEffectID(root, in: glass)
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

private struct FifthsWheel: View {
    let layout: FifthsLayout
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            ZStack {
                FifthsRing(layout: layout, ring: 0, glass: glass)
                FifthsRing(layout: layout, ring: 1, glass: glass)
            }
        }
    }
}

private struct FifthsRing: View {
    let layout: FifthsLayout
    let ring: Int
    let glass: Namespace.ID

    var body: some View {
        let band = layout.band(ring)
        let shape = RingShape(innerRadius: band.inner, outerRadius: band.outer)
        return ZStack {
            FifthsSpokes(inner: band.inner, outer: band.outer)
                .stroke(.primary.opacity(0.35), lineWidth: 1)
            ForEach(0..<12, id: \.self) { slice in
                FifthsLabel(item: layout.item(ring: ring, slice: slice))
            }
        }
        .frame(width: layout.size, height: layout.size)
        .contentShape(.interaction, Circle())
        .glassEffect(.clear.interactive(), in: shape)
        .glassEffectID(ring, in: glass)
    }
}

private struct FifthsLabel: View {
    let item: FifthsItem

    var body: some View {
        Text(item.label)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .minimumScaleFactor(0.4)
            .lineLimit(1)
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
    let outerR: CGFloat
    let outerInnerR: CGFloat
    let innerOuterR: CGFloat
    let innerInnerR: CGFloat

    init(size: CGFloat, gutter: CGFloat) {
        self.size = size
        outerR = size / 2
        let gap = gutter * 2
        let ringW = (outerR - gap) * 0.42
        outerInnerR = outerR - ringW
        innerOuterR = outerInnerR - gap
        innerInnerR = max(innerOuterR - ringW, outerR * 0.12)
    }

    func band(_ ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        ring == 0 ? (outerInnerR, outerR) : (innerInnerR, innerOuterR)
    }

    func item(ring: Int, slice: Int) -> FifthsItem {
        let r = band(ring)
        let mid = (r.inner + r.outer) / 2
        let c = size / 2
        let angle = Double(slice) * .pi / 6 - .pi / 2
        let chord = OmnichordChords.fifthsChord(slice: slice, ring: ring)
        return FifthsItem(
            label: OmnichordChords.label(root: chord.root, quality: chord.quality),
            labelSize: r.outer - r.inner,
            labelCenter: CGPoint(x: c + CGFloat(cos(angle)) * mid, y: c + CGFloat(sin(angle)) * mid)
        )
    }

    func item(root: Int, quality: Int) -> FifthsItem? {
        for ring in 0..<2 {
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
        let ring: Int
        if dist <= outerR && dist >= outerInnerR { ring = 0 }
        else if dist <= innerOuterR && dist >= innerInnerR { ring = 1 }
        else { return nil }
        var a = atan2(point.y - center.y, point.x - center.x) + .pi / 2 + .pi / 12
        if a < 0 { a += 2 * .pi }
        return OmnichordChords.fifthsChord(slice: min(11, Int(a / (.pi / 6))), ring: ring)
    }
}

private struct FifthsSpokes: Shape {
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        for slice in 0..<12 {
            let edge = Double(slice) * .pi / 6 - .pi / 2 - .pi / 12
            let inset: CGFloat = 8
            p.move(to: CGPoint(
                x: c.x + CGFloat(cos(edge)) * (inner + inset),
                y: c.y + CGFloat(sin(edge)) * (inner + inset)
            ))
            p.addLine(to: CGPoint(
                x: c.x + CGFloat(cos(edge)) * (outer - inset),
                y: c.y + CGFloat(sin(edge)) * (outer - inset)
            ))
        }
        return p
    }
}

private struct RingShape: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outerRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        p.addArc(center: c, radius: innerRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: true)
        return p
    }
}

private struct StrumPad: View {
    let pitches: [AUValue]
    let chordOn: Bool
    let horizontal: Bool
    let spacing: CGFloat
    let radius: CGFloat

    var body: some View {
        let count = chordOn ? max(pitches.count, 1) : 1
        let layout = horizontal
            ? AnyLayout(VStackLayout(spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        GlassEffectContainer(spacing: 0) {
            layout {
                ForEach(horizontal ? Array(0..<count) : Array((0..<count).reversed()), id: \.self) { _ in
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: radius, style: .continuous))
                }
            }
        }
    }
}
