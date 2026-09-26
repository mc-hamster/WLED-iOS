import SwiftUI

struct StudioPlaylistView: View {
    @ObservedObject var studio: StudioModel
    var existing: StudioPreset?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var steps: [StudioPlaylistStep] = []
    @State private var repeatCount = 0
    @State private var shuffle = false
    @State private var endPreset = 0
    @State private var isSaving = false
    private var scenes: [StudioPreset] { studio.presets.filter { !$0.isPlaylist } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist name") { TextField("Name your playlist", text: $name) }
                Section {
                    ForEach($steps) { $step in
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Scene", selection: $step.preset) {
                                ForEach(scenes) { Text($0.name).tag($0.id) }
                                if !scenes.contains(where: { $0.id == step.preset }) {
                                    Text("Missing scene \(step.preset)").tag(step.preset)
                                }
                            }
                            Stepper("Hold for \(step.duration.formatted(.number.precision(.fractionLength(1)))) s",
                                    value: $step.duration, in: 0.1...6553.5, step: 1)
                            Stepper("Transition · \(step.transition.formatted(.number.precision(.fractionLength(1)))) s",
                                    value: $step.transition, in: 0...65.5, step: 0.1)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { steps.remove(atOffsets: $0) }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        if let first = scenes.first { steps.append(StudioPlaylistStep(preset: first.id)) }
                    } label: { Label("Add a scene", systemImage: "plus") }
                        .disabled(scenes.isEmpty || steps.count >= 100)
                } header: { Text("Sequence") } footer: { Text("Use Edit to reorder or remove steps. Each step can have its own duration and transition.") }
                Section("Playback") {
                    Toggle("Shuffle", isOn: $shuffle)
                    Stepper(repeatCount == 0 ? "Repeat forever" : "Play \(repeatCount) times", value: $repeatCount, in: 0...127)
                    if repeatCount > 0 {
                        Picker("When finished", selection: $endPreset) {
                            Text("Keep the last scene").tag(0)
                            Text("Return to the starting scene").tag(255)
                            ForEach(scenes) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section {
                    Text("Saving a playlist starts playback on the device.").font(.callout).foregroundStyle(.secondary)
                }
                if let error = studio.error { Section { Text(error).foregroundStyle(.orange) } }
                if isSaving { Section { ProgressView("Saving and verifying…") } }
            }
            .navigationTitle(existing == nil ? "New playlist" : "Edit playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .bottomBar) {
                    Button("Save & play") { save() }.buttonStyle(.borderedProminent)
                        .disabled(isSaving || steps.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  (existing == nil && studio.nextPresetID == nil))
                }
            }
            .onAppear(perform: populate)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func populate() {
        guard let existing, let playlist = existing.raw["playlist"] as? [String: Any], let ids = playlist["ps"] as? [Int] else {
            if let first = scenes.first { steps = [StudioPlaylistStep(preset: first.id)] }
            return
        }
        name = existing.name
        let durations = playlist["dur"] as? [Int] ?? [playlist["dur"] as? Int ?? 100]
        let transitions = playlist["transition"] as? [Int] ?? [playlist["transition"] as? Int ?? 10]
        steps = ids.enumerated().map { index, id in
            StudioPlaylistStep(preset: id,
                               duration: Double(durations.indices.contains(index) ? durations[index] : durations.last ?? 100) / 10,
                               transition: Double(transitions.indices.contains(index) ? transitions[index] : transitions.last ?? 10) / 10)
        }
        repeatCount = playlist["repeat"] as? Int ?? 0
        shuffle = (playlist["r"] as? NSNumber)?.boolValue ?? false
        endPreset = playlist["end"] as? Int ?? 0
    }

    private func save() {
        guard let id = existing?.id ?? studio.nextPresetID else { return }
        let playlist: [String: Any] = ["ps": steps.map(\.preset), "dur": steps.map { Int(($0.duration * 10).rounded()) },
                                       "transition": steps.map { Int(($0.transition * 10).rounded()) },
                                       "repeat": repeatCount, "r": shuffle, "end": endPreset]
        isSaving = true
        Task {
            let saved = await studio.savePreset(id: id, name: String(name.prefix(32)), contents: ["playlist": playlist])
            isSaving = false
            if saved { dismiss() }
        }
    }
}
