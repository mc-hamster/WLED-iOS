import SwiftUI

struct StudioSegmentsView: View {
    @ObservedObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: StudioSegment?
    @State private var deleting: StudioSegment?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(studio.segments) { segment in
                        HStack(spacing: 12) {
                            Button {
                                studio.selectedSegmentID = segment.id
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 10).fill(segment.color(at: 0).gradient)
                                        .frame(width: 40, height: 44).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(segment.name).font(.headline).foregroundStyle(.primary)
                                        Text("LEDs \(segment.number("start"))–\(max(segment.number("start"), segment.number("stop") - 1))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if segment.id == studio.selectedSegmentID {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(segment.id == studio.selectedSegmentID ? [.isSelected] : [])
                            Button { editing = segment } label: {
                                Label("Edit \(segment.name)", systemImage: "slider.horizontal.3")
                                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            if studio.segments.count > 1 {
                                Button("Delete", role: .destructive) { deleting = segment }
                            }
                        }
                    }
                } footer: {
                    Text("Choose the segment you want to control. Each segment can have its own colors, effect and brightness.")
                }
                Section {
                    Button { addSegment() } label: { Label("Add segment", systemImage: "plus") }
                        .disabled(studio.nextSegmentID == nil || !studio.device.isOnline)
                }
                if let error = studio.error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle("Segments")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { StudioSegmentEditor(studio: studio, segment: $0) }
            .confirmationDialog("Delete \(deleting?.name ?? "segment")?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("Delete segment", role: .destructive) {
                    guard let deleting else { return }
                    studio.send(["seg": [["id": deleting.id, "stop": 0]]])
                    self.deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("This removes the segment from the current light layout. Saved scenes are unchanged.") }
        }
    }

    private func addSegment() {
        guard let id = studio.nextSegmentID else { return }
        var fields: [String: Any] = ["id": id, "start": 0, "stop": max(1, studio.ledCount), "grp": 1, "bri": 255, "on": true]
        if let matrix = (studio.info["leds"] as? [String: Any])?["matrix"] as? [String: Any] {
            fields["stop"] = matrix["w"] as? Int ?? max(1, studio.ledCount)
            fields["startY"] = 0
            fields["stopY"] = matrix["h"] as? Int ?? 1
        }
        editing = StudioSegment(raw: fields)
    }
}
