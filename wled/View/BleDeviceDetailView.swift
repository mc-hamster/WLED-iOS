import SwiftUI

struct BleDeviceDetailView: View {
    @ObservedObject var device: DeviceWithState
    let onSendState: (WledState) -> Void
    let onReconnect: () -> Void
    @StateObject private var studio: StudioModel
    @State private var showConnection = false
    @State private var section = Section.light
    @State private var showSegments = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Section: String, CaseIterable {
        case light = "Light", effects = "Effects", scenes = "Scenes"
    }

    init(device: DeviceWithState, onSendState: @escaping (WledState) -> Void, onReconnect: @escaping () -> Void) {
        self.device = device
        self.onSendState = onSendState
        self.onReconnect = onReconnect
        _studio = StateObject(wrappedValue: StudioModel(device: device))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionStatus
                hero
                Picker("Studio section", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if let error = studio.error { feedback(error, systemImage: "exclamationmark.circle", isError: true) }
                if let notice = studio.notice { feedback(notice, systemImage: "checkmark.circle", isError: false) }
                Group {
                    switch section {
                    case .light: StudioLightView(studio: studio)
                    case .effects: StudioEffectsView(studio: studio)
                    case .scenes: StudioScenesView(studio: studio)
                    }
                }
                .disabled(!device.isOnline)
                advanced
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .environment(\.studioControlRevision, studio.controlRevision)
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(.accentColor)
        .navigationTitle(device.device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnection) { ConnectionView(device: device) }
        .sheet(isPresented: $showSegments) { StudioSegmentsView(studio: studio) }
        .refreshable {
            await studio.refresh()
            if section == .effects { await studio.loadCatalogs(force: true) }
            if section == .scenes { await studio.loadPresets(force: true) }
        }
        .task(id: "\(device.isOnline)-\(device.connectionEpoch)") {
            guard device.isOnline else { return }
            await studio.refresh()
            await studio.loadCatalogs()
        }
        .onChange(of: device.connectionEpoch) { _ in
            studio.controlRevision += 1
            studio.cancelPendingColorChanges()
            studio.catalogsLoaded = false
            studio.libraryLoaded = false
            studio.paletteColors = [:]
        }
        .onDisappear { studio.cancelPendingColorChanges() }
        .onReceive(device.$stateInfo) { value in studio.ingest(value?.state) }
        .onReceive(device.$rawStatePayload) { value in studio.ingest(rawPayload: value) }
        .onChange(of: section) { selected in
            Task {
                if selected == .effects { await studio.loadCatalogs() }
                if selected == .scenes { await studio.loadPresets() }
            }
        }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            adaptiveRow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: device.isOnline ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 17))
                        .foregroundStyle(device.isOnline ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    Text(device.connectionSummary).font(.caption).bold()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if studio.isSaving || device.isSending || device.websocketStatus == .connecting {
                    ProgressView().accessibilityLabel(studio.isSaving ? "Confirming your change" : "Connecting")
                }
                Button("Connection") { showConnection = true }
                    .font(.caption).bold().frame(minHeight: 44)
            }
            if let message = device.connectionError ?? device.recoveryMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if !device.isOnline {
                if let date = device.lastConfirmedAt {
                    Text("Last confirmed \(date.formatted(date: .omitted, time: .shortened)). Reconnect to see live values.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !device.manuallyDisconnected { Button("Reconnect", action: onReconnect).buttonStyle(.bordered) }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("LIGHT STUDIO").font(.caption).bold().tracking(2)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(.white.opacity(0.72)).accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Image(systemName: studio.stateFlag("on") ? "lightbulb.max.fill" : "moon.stars.fill")
                        .font(.title).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(.white.opacity(0.9)).accessibilityHidden(true)
                }
                Text(studio.stateFlag("on") ? studio.effectName : "A moment of quiet")
                    .font(.system(.largeTitle, design: .rounded)).bold()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(studio.stateFlag("on") ? "\(Int(Double(studio.stateNumber("bri")) / 255 * 100))% brightness" : "Your lights are off")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            adaptiveRow {
                Button { showSegments = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 20))
                        Text(studio.segment?.name ?? "Segments")
                            .font(.subheadline).bold().multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 22))
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .disabled(!device.isOnline)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                HStack {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Power").font(.subheadline).bold()
                        Spacer()
                    }
                    Toggle("Power", isOn: Binding(
                        get: { studio.stateFlag("on") },
                        set: { onSendState(WledState(isOn: $0)) }
                    ))
                    .labelsHidden().tint(.white.opacity(0.45)).fixedSize()
                    .accessibilityLabel("Power")
                    .disabled(!device.isOnline)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(red: 0.075, green: 0.085, blue: 0.12)
                LinearGradient(colors: [studio.accent.opacity(studio.stateFlag("on") ? 0.62 : 0.16), .clear],
                               startPoint: .bottomTrailing, endPoint: .topLeading)
                RadialGradient(colors: [.white.opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 260)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private var adaptiveRow: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 8))
    }

    private var advanced: some View {
        NavigationLink {
            DeviceWebInterfaceView(device: device)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advanced controls").font(.subheadline).bold()
                    Text("Settings, files, mapping & more").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).bold().foregroundStyle(.secondary)
            }
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studio-advanced-controls")
        .disabled(!device.isOnline)
    }

    private func feedback(_ text: String, systemImage: String, isError: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(isError ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
    }
}
