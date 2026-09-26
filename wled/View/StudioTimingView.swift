import SwiftUI

struct StudioTimingView: View {
    @ObservedObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var duration = 60
    @State private var mode = 1
    @State private var target = 0.0
    @State private var isSubmitting = false
    private var nightlight: [String: Any] { studio.state["nl"] as? [String: Any] ?? [:] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StudioSlider(title: "Transition", value: Double(studio.stateNumber("transition")) / 10,
                                 range: 0...60, unit: " s") { studio.send(["transition": Int(($0 * 10).rounded())]) }
                } footer: { Text("How gently your lights move between colors and brightness levels.") }
                Section("Sleep timer") {
                    if nightlight["on"] as? Bool == true {
                        Label("Timer running", systemImage: "moon.zzz.fill")
                        if let remaining = nightlight["rem"] as? Int, remaining > 0 {
                            Text("About \(max(1, remaining / 60)) minutes remaining").foregroundStyle(.secondary)
                        }
                    }
                    Stepper("\(duration) minutes", value: $duration, in: 1...255)
                    Picker("Mode", selection: $mode) {
                        Text("Fade brightness").tag(1)
                        Text("Fade color").tag(2)
                        Text("Wait, then switch").tag(0)
                        Text("Sunrise / sunset").tag(3)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Target brightness · \(Int(target / 255 * 100))%")
                        Slider(value: $target, in: 0...255, step: 1).accessibilityLabel("Target brightness")
                    }
                    Button(nightlight["on"] as? Bool == true ? "Restart timer" : "Start timer") {
                        submit(["on": true, "dur": duration, "mode": mode, "tbri": Int(target)])
                    }
                    .disabled(isSubmitting)
                    if nightlight["on"] as? Bool == true {
                        Button("Stop timer", role: .destructive) { submit(["on": false]) }
                            .disabled(isSubmitting)
                    }
                }
                if let error = studio.error { Section { Text(error).foregroundStyle(.orange) } }
                if isSubmitting { ProgressView("Confirming timer…") }
            }
            .navigationTitle("Timing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                duration = max(1, nightlight["dur"] as? Int ?? 60)
                mode = nightlight["mode"] as? Int ?? 1
                target = Double(nightlight["tbri"] as? Int ?? 0)
            }
        }
    }

    private func submit(_ value: [String: Any]) {
        isSubmitting = true
        Task {
            _ = await studio.apply(["nl": value])
            isSubmitting = false
        }
    }
}
