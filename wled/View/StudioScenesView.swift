import SwiftUI

struct StudioScenesView: View {
    @ObservedObject var studio: StudioModel
    @State private var showSave = false
    @State private var showPlaylist = false
    @State private var editingPlaylist: StudioPreset?
    @State private var renaming: StudioPreset?
    @State private var deleting: StudioPreset?
    @State private var replacement: StudioPreset?
    @State private var newName = ""
    @State private var search = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var matches: [StudioPreset] {
        studio.presets.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(spacing: 20) {
            StudioCard {
                headerLayout {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Made for your moments").font(.system(.title2, design: .rounded)).bold()
                        Text("Keep a look. Set a rhythm.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Menu {
                        Button { showSave = true } label: { Label("Save current light", systemImage: "plus") }
                        Button { showPlaylist = true } label: { Label("Create playlist", systemImage: "music.note.list") }
                            .disabled(studio.presets.filter { !$0.isPlaylist }.isEmpty)
                        Button { Task { await studio.loadPresets(force: true) } } label: {
                            Label("Refresh scenes", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        if dynamicTypeSize.isAccessibilitySize {
                            Text("Scene options").font(.subheadline).bold().frame(minHeight: 44)
                        } else {
                            Label("Scene options", systemImage: "plus.circle.fill").font(.title2)
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    }
                }
                if studio.isLoadingLibrary { ProgressView("Reading scenes from your device…").font(.caption) }
                if let error = studio.libraryError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    Button("Reload scenes") { Task { await studio.loadPresets(force: true) } }
                }
                if studio.stateNumber("pl", default: -1) >= 0 {
                    Button { studio.send(["playlist": ["ps": []]]) } label: {
                        Label("Stop playlist", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if studio.presets.isEmpty && !studio.isLoadingLibrary {
                StudioCard {
                    Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.tint)
                    Text(studio.libraryLoaded ? "A place for your favorites" : "Your scene library").font(.headline)
                    Text(studio.libraryLoaded ? "Save the current light as your first scene. It stays on the device, ready whenever you need it." : "Connect and refresh to read the scenes stored on your device.")
                        .font(.callout).foregroundStyle(.secondary)
                    if studio.libraryLoaded {
                        Button("Save current light") { showSave = true }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a scene", text: $search).textInputAutocapitalization(.never)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                LazyVStack(spacing: 12) {
                    ForEach(matches) { scene in sceneRow(scene) }
                    if matches.isEmpty { Text("No scenes match that name.").foregroundStyle(.secondary).padding() }
                }
            }
        }
        .task { await studio.loadPresets() }
        .sheet(isPresented: $showSave) { StudioSaveSceneView(studio: studio) }
        .sheet(isPresented: $showPlaylist) { StudioPlaylistView(studio: studio) }
        .sheet(item: $editingPlaylist) { StudioPlaylistView(studio: studio, existing: $0) }
        .alert(studio.device.activeTransport == .ble ? "Rename scene" : "Rename & apply scene", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Scene name", text: $newName)
            Button(studio.device.activeTransport == .ble ? "Save" : "Save & apply") {
                if let scene = renaming { Task { _ = await studio.renamePreset(scene, name: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "scene")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete scene", role: .destructive) {
                if let scene = deleting { Task { _ = await studio.deletePreset(scene) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("The scene will be removed from this device. Playlists that use it will need to be updated.") }
        .confirmationDialog("Replace \(replacement?.name ?? "scene")?", isPresented: Binding(
            get: { replacement != nil }, set: { if !$0 { replacement = nil } }
        ), titleVisibility: .visible) {
            Button("Replace with current light", role: .destructive) {
                if let scene = replacement { Task { _ = await studio.savePreset(id: scene.id, name: scene.name) } }
                replacement = nil
            }
            Button("Cancel", role: .cancel) { replacement = nil }
        } message: { Text("The current colors, effects and segment layout will replace this saved scene.") }
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    private func sceneRow(_ scene: StudioPreset) -> some View {
        let isActive = studio.stateNumber(scene.isPlaylist ? "pl" : "ps", default: -1) == scene.id
        return HStack(spacing: 12) {
            Button { studio.send(["ps": scene.id]) } label: {
                HStack(spacing: 14) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: scene.isPlaylist ? "play.square.stack.fill" : "sparkles")
                            .font(.title2).foregroundStyle(.tint)
                            .frame(width: 48, height: 52)
                            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(scene.name).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Text("\(scene.isPlaylist ? "Playlist" : "Scene") · \(scene.id)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isActive { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.tint).accessibilityHidden(true) }
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(scene.name)")
            .accessibilityIdentifier("studio-scene-\(scene.id)")
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            Menu {
                Button(studio.device.activeTransport == .ble ? "Rename" : "Rename & apply") { newName = scene.name; renaming = scene }
                if scene.isPlaylist { Button("Edit playlist") { editingPlaylist = scene } } else { Button("Replace with current light") { replacement = scene } }
                Button("Delete", role: .destructive) { deleting = scene }
            } label: {
                Label("Options for \(scene.name)", systemImage: "ellipsis").labelStyle(.iconOnly)
                    .font(.system(size: 20))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(studio.isSaving)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}
