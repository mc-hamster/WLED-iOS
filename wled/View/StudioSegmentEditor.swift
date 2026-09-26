import SwiftUI

struct StudioSegmentEditor: View {
    @ObservedObject var studio: StudioModel
    let segment: StudioSegment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = "0"
    @State private var stop = "1"
    @State private var startY = "0"
    @State private var stopY = "1"
    @State private var grouping = "1"
    @State private var spacing = "0"
    @State private var offset = "0"
    @State private var reverse = false
    @State private var mirror = false
    @State private var reverseY = false
    @State private var mirrorY = false
    @State private var transpose = false
    @State private var selected = true
    @State private var mapping = 0
    @State private var soundSimulation = 0
    @State private var segmentSet = 0
    @State private var blendMode = 0
    @State private var isSaving = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Segment name", text: $name).textInputAutocapitalization(.sentences)
                    Toggle("Include in group changes", isOn: $selected)
                    Stepper("Segment set \(segmentSet)", value: $segmentSet, in: 0...3)
                }
                Section {
                    numericField(segment.isMatrix ? "Start X" : "First LED", text: $start)
                    numericField(segment.isMatrix ? "Stop X" : "Stop LED", text: $stop)
                    if segment.isMatrix {
                        numericField("Start Y", text: $startY)
                        numericField("Stop Y", text: $stopY)
                    }
                } header: { Text("Range") } footer: { Text("The first LED is included. The stop value is the first LED outside this segment.") }
                Section("Pattern") {
                    numericField("Grouping", text: $grouping)
                    numericField("Spacing", text: $spacing)
                    numericField("Offset", text: $offset)
                    Toggle("Reverse", isOn: $reverse)
                    Toggle("Mirror", isOn: $mirror)
                    Picker("Blend mode", selection: $blendMode) {
                        let labels = ["Top / default", "Bottom / none", "Add", "Subtract", "Difference", "Average", "Multiply", "Divide", "Lighten", "Darken", "Screen", "Overlay", "Hard light", "Soft light", "Dodge", "Burn", "Stencil"]
                        ForEach(labels.indices, id: \.self) { Text(labels[$0]).tag($0) }
                    }
                    if segment.isMatrix {
                        Toggle("Reverse Y", isOn: $reverseY)
                        Toggle("Mirror Y", isOn: $mirrorY)
                        Toggle("Transpose X / Y", isOn: $transpose)
                        Picker("1D effect mapping", selection: $mapping) {
                            Text("Pixels").tag(0)
                            Text("Bar").tag(1)
                            Text("Arc").tag(2)
                            Text("Corner").tag(3)
                            Text("Pinwheel").tag(4)
                        }
                    }
                }
                Section("Audio-reactive effects") {
                    Picker("Sound simulation", selection: $soundSimulation) {
                        Text("Beat / sine").tag(0)
                        Text("Rock").tag(1)
                        Text("10 / 13").tag(2)
                        Text("14 / 3").tag(3)
                    }
                }
                if let message = validationError ?? studio.error {
                    Section { Text(message).foregroundStyle(.orange) }
                }
                if isSaving { Section { ProgressView("Confirming segment…") } }
            }
            .navigationTitle("Edit segment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold().disabled(isSaving || !studio.device.isOnline)
                }
            }
            .onAppear(perform: populate)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func numericField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .frame(maxWidth: 100).accessibilityLabel(title)
        }
    }

    private func populate() {
        name = segment.raw["n"] as? String ?? ""
        start = String(segment.number("start")); stop = String(segment.number("stop", default: 1))
        startY = String(segment.number("startY")); stopY = String(segment.number("stopY", default: 1))
        grouping = String(segment.number("grp", default: 1)); spacing = String(segment.number("spc"))
        offset = String(segment.number("of"))
        reverse = segment.flag("rev"); mirror = segment.flag("mi")
        reverseY = segment.flag("rY"); mirrorY = segment.flag("mY"); transpose = segment.flag("tp")
        selected = segment.flag("sel", default: true)
        mapping = segment.number("m12"); soundSimulation = segment.number("si")
        segmentSet = segment.number("set"); blendMode = segment.number("bm")
    }

    private func save() {
        guard let first = Int(start), let end = Int(stop), let group = Int(grouping),
              let gap = Int(spacing), let shift = Int(offset), first >= 0, end > first, end <= 65535,
              (1...255).contains(group), (0...255).contains(gap), (0...65535).contains(shift) else {
            validationError = "Enter a valid range, grouping from 1–255, spacing from 0–255, and a nonnegative offset."
            return
        }
        var payload: [String: Any] = [
            "id": segment.id, "n": StudioPreset.validName(name), "start": first, "stop": end,
            "grp": group, "spc": gap, "of": shift, "rev": reverse, "mi": mirror,
            "sel": selected, "si": soundSimulation, "set": segmentSet, "bm": blendMode
        ]
        if segment.isMatrix {
            guard let firstY = Int(startY), let endY = Int(stopY), firstY >= 0, endY > firstY, endY <= 65535 else {
                validationError = "The Y range must end after it starts."
                return
            }
            payload.merge(["startY": firstY, "stopY": endY, "rY": reverseY, "mY": mirrorY, "tp": transpose, "m12": mapping]) { _, new in new }
        }
        validationError = nil
        isSaving = true
        Task {
            let saved = await studio.apply(["seg": [payload]])
            isSaving = false
            if saved { studio.selectedSegmentID = segment.id; dismiss() }
        }
    }
}
