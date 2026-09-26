import SwiftUI

struct StudioLightView: View {
    @ObservedObject var studio: StudioModel
    @State private var colorSlot = 0
    @State private var showTiming = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 20) {
            StudioCard {
                StudioSlider(title: "Brightness", value: Double(studio.stateNumber("bri", default: 128)), range: 1...255) {
                    studio.send(["bri": Int($0)])
                }
            }
            if let segment = studio.segment {
                StudioCard {
                    adaptiveRow {
                        Text("Color & warmth").font(.headline)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Text(segment.name).font(.caption).foregroundStyle(.secondary)
                    }
                    if segment.supportsRGB {
                        Picker("Color slot", selection: $colorSlot) {
                            Text("Primary").tag(0)
                            Text("Background").tag(1)
                            Text("Accent").tag(2)
                        }
                        .pickerStyle(.segmented)
                        ColorPicker("Color", selection: Binding(
                            get: { segment.color(at: colorSlot) },
                            set: { studio.setColor($0, slot: colorSlot) }
                        ), supportsOpacity: false)
                        .font(.subheadline).bold()
                        .padding(.vertical, 4)
                        warmSwatches
                    }
                    if segment.supportsWhite {
                        StudioSlider(title: "White channel", value: Double(whiteValue(segment))) {
                            studio.setWhite(Int($0), slot: colorSlot)
                        }
                    }
                    if segment.supportsCCT {
                        StudioSlider(title: "White temperature", value: Double(segment.number("cct", default: 127)),
                                     detail: "Warm at the left · cool at the right") {
                            studio.sendSegment(["cct": Int($0)])
                        }
                    }
                    if !segment.supportsRGB && !segment.supportsWhite && !segment.supportsCCT {
                        Text("This output supports brightness control.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                StudioCard {
                    adaptiveRow {
                        Text("\(segment.name) controls").font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        HStack {
                            if dynamicTypeSize.isAccessibilitySize {
                                Text("Power").font(.subheadline)
                                Spacer()
                            }
                            Toggle("Segment power", isOn: Binding(get: { segment.flag("on", default: true) },
                                                                   set: { studio.sendSegment(["on": $0]) }))
                                .labelsHidden().accessibilityLabel("Segment power")
                        }
                    }
                    StudioSlider(title: "Segment brightness", value: Double(segment.number("bri", default: 255)), range: 1...255) {
                        studio.sendSegment(["bri": Int($0)])
                    }
                }
            }
            StudioCard {
                Button { showTiming = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "moon.zzz").font(.title3).dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transitions & sleep timer").font(.subheadline).bold()
                            Text(timingSummary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showTiming) { StudioTimingView(studio: studio) }
    }

    private var adaptiveRow: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
    }

    private var timingSummary: String {
        let nightlight = studio.state["nl"] as? [String: Any] ?? [:]
        if nightlight["on"] as? Bool == true { return "Sleep timer is running" }
        let seconds = Double(studio.stateNumber("transition")) / 10
        return "\(seconds.formatted(.number.precision(.fractionLength(1)))) s transition · sleep timer off"
    }

    private func whiteValue(_ segment: StudioSegment) -> Int {
        guard segment.colors.indices.contains(colorSlot), segment.colors[colorSlot].count > 3 else { return 0 }
        return segment.colors[colorSlot][3]
    }

    private var warmSwatches: some View {
        let swatches: [(String, Color)] = [
            ("Candlelight", Color(red: 1, green: 0.42, blue: 0.12)),
            ("Warm white", Color(red: 1, green: 0.74, blue: 0.47)),
            ("Rose", Color(red: 1, green: 0.18, blue: 0.4)),
            ("Lavender", Color(red: 0.57, green: 0.32, blue: 1)),
            ("Ocean", Color(red: 0.10, green: 0.60, blue: 1)),
            ("Mint", Color(red: 0.16, green: 1, blue: 0.60))
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { swatchButtons(swatches) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 8) { swatchButtons(swatches) }
        }
    }

    private func swatchButtons(_ swatches: [(String, Color)]) -> some View {
        ForEach(swatches, id: \.0) { name, color in
            Button { studio.setColor(color, slot: colorSlot) } label: {
                Circle().fill(color.gradient)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
                    .frame(width: 32, height: 32)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
        }
    }
}
