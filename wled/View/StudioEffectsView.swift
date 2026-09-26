import SwiftUI

struct StudioEffectsView: View {
    @ObservedObject var studio: StudioModel
    @State private var showEffects = false
    @State private var showPalettes = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 20) {
            StudioCard {
                Text("Find your mood").font(.system(.title2, design: .rounded)).bold()
                Text("Explore motion and color for \(studio.segment?.name.lowercased() ?? "your lights").")
                    .font(.subheadline).foregroundStyle(.secondary)
                catalogButton("Effect", value: studio.effectName, systemImage: "sparkles") { showEffects = true }
                Divider()
                catalogButton("Palette", value: studio.paletteName, systemImage: "paintpalette") { showPalettes = true }
                if studio.isLoadingLibrary { ProgressView("Loading your device’s library…").font(.caption) }
                if let error = studio.libraryError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    Button("Retry library") { Task { await studio.loadCatalogs(force: true) } }
                }
            }
            if !studio.parameters.isEmpty {
                StudioCard {
                    Text("Make it yours").font(.headline)
                    ForEach(studio.parameters) { parameter in
                        if parameter.isToggle {
                            Toggle(parameter.title, isOn: Binding(
                                get: { studio.segment?.flag(parameter.key) ?? false },
                                set: { studio.sendSegment([parameter.key: $0]) }
                            ))
                        } else {
                            StudioSlider(title: parameter.title,
                                         value: Double(studio.segment?.number(parameter.key, default: 128) ?? 128),
                                         range: 0...parameter.maximum) {
                                studio.sendSegment([parameter.key: Int($0)])
                            }
                        }
                    }
                }
            }
            StudioCard {
                Toggle("Freeze animation", isOn: Binding(
                    get: { studio.segment?.flag("frz") ?? false },
                    set: { studio.sendSegment(["frz": $0]) }
                ))
                Text("Hold this moment while keeping the lights on.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showEffects) { StudioCatalogView(studio: studio, kind: .effects) }
        .sheet(isPresented: $showPalettes) { StudioCatalogView(studio: studio, kind: .palettes) }
    }

    private func catalogButton(_ title: String, value: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: systemImage).font(.title2).frame(width: 32).foregroundStyle(.tint).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.headline).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.vertical, 6).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studio-\(title.lowercased())-picker")
    }
}
