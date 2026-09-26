import SwiftUI

struct StudioSaveSceneView: View {
    @ObservedObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Give this moment a name", text: $name).textInputAutocapitalization(.sentences)
                } header: { Text("Scene name") } footer: {
                    Text("Saves colors, effects, brightness and the segment layout on your device.")
                }
                if let id = studio.nextPresetID {
                    Section { LabeledContent("Scene number", value: String(id)) }
                } else { Section { Text("All 250 scene slots are used. Delete a scene to make room.").foregroundStyle(.orange) } }
                if isSaving { Section { ProgressView("Saving and verifying…") } }
                if let error = studio.error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle("Save a scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold()
                        .disabled(isSaving || studio.nextPresetID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() {
        guard let id = studio.nextPresetID else { return }
        isSaving = true
        Task {
            let saved = await studio.savePreset(id: id, name: String(name.prefix(32)))
            isSaving = false
            if saved { dismiss() }
        }
    }
}
