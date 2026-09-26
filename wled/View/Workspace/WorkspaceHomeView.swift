import SwiftUI

struct WorkspaceHomeView: View {
    let navigate: (String) -> Void
    private struct Destination: Identifiable {
        let title: String
        let detail: String
        let icon: String
        let path: String
        var id: String { path }
    }
    private let controller = [
        Destination(title: "LED setup", detail: "Outputs, power limits & color order", icon: "lightbulb.led.fill", path: "/settings/leds"),
        Destination(title: "Matrix layout", detail: "Panels, orientation & mapping", icon: "square.grid.3x3.fill", path: "/settings/2D"),
        Destination(title: "Connections", detail: "Wi-Fi settings & access point", icon: "wifi", path: "/settings/wifi"),
        Destination(title: "Sync & integrations", detail: "Other lights, remotes & services", icon: "arrow.triangle.branch", path: "/settings/sync"),
        Destination(title: "Time & automation", detail: "Schedules, buttons & infrared", icon: "clock.fill", path: "/settings/time"),
        Destination(title: "Extensions", detail: "Usermods & shared hardware pins", icon: "puzzlepiece.extension.fill", path: "/settings/um")]
    private let personalize = [
        Destination(title: "Appearance", detail: "Device name, themes & holidays", icon: "paintbrush.pointed.fill", path: "/settings/ui"),
        Destination(title: "Custom palettes", detail: "Build your own color combinations", icon: "paintpalette.fill", path: "/cpal.htm"),
        Destination(title: "Pixel studio", detail: "Draw, animate & import artwork", icon: "square.grid.3x3.square", path: "/pixelforge.htm"),
        Destination(title: "Live preview", detail: "See the current LED output", icon: "eye.fill", path: "/liveview")]
    private let manage = [
        Destination(title: "Security & backups", detail: "Settings PIN, backup & restore", icon: "lock.shield.fill", path: "/settings/sec"),
        Destination(title: "Files", detail: "Presets, maps, palettes & custom assets", icon: "folder.fill", path: "/edit"),
        Destination(title: "Pin overview", detail: "Hardware assignments & capabilities", icon: "cpu", path: "/settings/pins"),
        Destination(title: "Full controls", detail: "Every control in the WLED interface", icon: "slider.horizontal.3", path: "/")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make it your own.")
                        .font(.system(.largeTitle, design: .rounded)).bold()
                    Text("Tune your controller, create something new, and keep your favorite looks safe.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 8)
                destinations("Controller", items: controller, color: .indigo)
                destinations("Create", items: personalize, color: .pink)
                destinations("Manage", items: manage, color: .teal)
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func destinations(_ title: String, items: [Destination], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).padding(.leading, 5)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button { navigate(item.path) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.icon).font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(color).frame(width: 44, height: 44)
                                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline).bold().foregroundStyle(.primary)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption).bold().foregroundStyle(.tertiary)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace-" + item.path)
                    if item.id != items.last?.id { Divider().padding(.leading, 74) }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
