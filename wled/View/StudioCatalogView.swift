import SwiftUI

struct StudioCatalogView: View {
    enum Kind { case effects, palettes }
    @ObservedObject var studio: StudioModel
    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selecting: Int?

    private var entries: [StudioCatalogEntry] { kind == .effects ? studio.effects.enumerated().map { StudioCatalogEntry(id: $0.offset, name: $0.element) } : studio.paletteEntries }
    private var selectedID: Int { kind == .effects ? studio.effectID : studio.paletteID }
    private var matches: [StudioCatalogEntry] { entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matches) { entry in
                        let id = entry.id
                        Button { select(id) } label: {
                            HStack(spacing: 16) {
                                if kind == .palettes { paletteSwatch(id) }
                                Text(entry.name).foregroundStyle(.primary)
                                Spacer()
                                if selecting == id { ProgressView() } else if selectedID == id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(entry.name)
                        .accessibilityIdentifier("studio-catalog-\(kind == .effects ? "effect" : "palette")-\(id)")
                        .disabled(selecting != nil || !studio.device.isOnline)
                        .accessibilityAddTraits(selectedID == id ? [.isSelected] : [])
                    }
                } header: {
                    Text("\(entries.count) \(kind == .effects ? "effects" : "palettes") on your device")
                }
                if matches.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.title2)
                        Text(entries.isEmpty ? "The library is not loaded yet." : "No matches. Try another name.")
                    }
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                if let error = studio.libraryError ?? studio.error {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        Button("Reload library") { Task { await studio.loadCatalogs(force: true) } }
                    }
                }
            }
            .searchable(text: $search, prompt: kind == .effects ? "Find an effect" : "Find a palette")
            .navigationTitle(kind == .effects ? "Effects" : "Palettes")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await studio.loadCatalogs()
                if kind == .palettes { await studio.loadPalettePreviews() }
            }
        }
    }

    private func select(_ id: Int) {
        guard let segment = studio.segment else { return }
        selecting = id
        Task {
            let succeeded = await studio.apply(["seg": [["id": segment.id, kind == .effects ? "fx" : "pal": id, "fxdef": true]]])
            selecting = nil
            if succeeded { dismiss() }
        }
    }

    private func paletteSwatch(_ id: Int) -> some View {
        Group {
            if let colors = studio.paletteColors[id], !colors.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            } else {
                Image(systemName: "paintpalette").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: 68, height: 36)
        .accessibilityHidden(true)
    }
}
