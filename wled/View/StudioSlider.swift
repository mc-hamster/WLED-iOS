import SwiftUI

/// Keep an in-progress drag local, then send one command on release and return to confirmed state.
struct StudioSlider: View {
    let title: String
    let value: Double
    var range: ClosedRange<Double> = 0...255
    var unit: String = "%"
    var detail: String?
    let onCommit: (Double) -> Void
    @State private var draft = 0.0
    @State private var editing = false
    @Environment(\.studioControlRevision) private var revision
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var formattedValue: String {
        if unit == "%" { return "\(Int((draft / max(range.upperBound, 1) * 100).rounded()))%" }
        return "\(draft.formatted(.number.precision(.fractionLength(range.upperBound <= 60 ? 1 : 0))))\(unit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelLayout {
                Text(title).font(.subheadline).bold()
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Text(formattedValue).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: $draft, in: range, step: unit == " s" ? 0.1 : 1) { changing in
                editing = changing
                if !changing { onCommit(draft) }
            }
            .accessibilityLabel(title)
            .accessibilityValue(formattedValue)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { draft = min(range.upperBound, max(range.lowerBound, value)) }
        .onChange(of: revision) { _ in
            if !editing { draft = min(range.upperBound, max(range.lowerBound, value)) }
        }
        .onChange(of: value) { updated in
            if !editing { draft = min(range.upperBound, max(range.lowerBound, updated)) }
        }
    }

    private var labelLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }
}
