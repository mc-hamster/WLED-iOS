import XCTest
import SwiftUI
import UIKit
import CoreData
@testable import WLED

/// Renders hosted production views inside the test process. This deliberately avoids
/// XCUIApplication.screenshot() and the CoreSimulator screenshot daemon.
@MainActor
final class StudioRenderingTests: XCTestCase {
    func testRenderNativeStudioAndWorkspace() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Design rendering is isolated to Simulator")
        #endif
        let fixture = StudioPreviewFixture()
        let model = StudioModel(device: fixture.device)
        model.state = fixture.state
        model.info = fixture.info
        model.effects = fixture.effects
        model.palettes = fixture.palettes
        model.effectMetadata = fixture.effects.map { _ in "Speed,Intensity,Custom 1,Custom 2,Custom 3,Option 1,Option 2,Option 3;!,!,!;!" }
        model.presets = StudioPreset.decode(fixture.presets)
        model.libraryLoaded = true
        model.catalogsLoaded = true

        try await render("01-light-studio", fixture: fixture) {
            DeviceView(device: fixture.device)
        }
        try await render("02-effects", fixture: fixture) {
            self.studioPage(title: "Effects") { StudioEffectsView(studio: model) }
        }
        try await render("03-scenes", fixture: fixture) {
            self.studioPage(title: "Scenes") { StudioScenesView(studio: model) }
        }
        try await render("04-workspace", fixture: fixture) {
            WorkspaceHomeView { _ in }.navigationTitle("Device workspace").navigationBarTitleDisplayMode(.inline)
        }
        try await render("05-light-accessibility-xxxl", fixture: fixture, dynamicType: .accessibility5, height: 1200) {
            DeviceView(device: fixture.device)
        }
        try await render("06-effects-accessibility-xxxl", fixture: fixture, dynamicType: .accessibility5, height: 1200) {
            self.studioPage(title: "Effects") { StudioEffectsView(studio: model) }
        }
        try await render("07-workspace-dark", fixture: fixture, colorScheme: .dark) {
            WorkspaceHomeView { _ in }.navigationTitle("Device workspace").navigationBarTitleDisplayMode(.inline)
        }
        try await render("08-light-dark", fixture: fixture, colorScheme: .dark) {
            DeviceView(device: fixture.device)
        }
    }

    private func studioPage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content().padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func render<Content: View>(_ name: String, fixture: StudioPreviewFixture,
                                       dynamicType: DynamicTypeSize = .large,
                                       colorScheme: ColorScheme = .light,
                                       height: CGFloat = 844,
                                       @ViewBuilder content: () -> Content) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let size = CGSize(width: 390, height: height)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let root = NavigationStack { content() }
            .environment(\.managedObjectContext, fixture.persistence.container.viewContext)
            .environment(\.dynamicTypeSize, dynamicType)
            .environment(\.colorScheme, colorScheme)
            .transaction { $0.disablesAnimations = true }
        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        // Give SwiftUI's display pass and the fixture's immediate catalog tasks a chance to finish.
        try await Task.sleep(for: .milliseconds(350))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var completedDrawing = false
        let image = renderer.image { _ in
            completedDrawing = controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        XCTAssertTrue(completedDrawing, "Hosted view did not complete rendering")
        let bytes = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(bytes.count, 5000, "Render appears empty")
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("StudioRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name + ".png")
        try bytes.write(to: file, options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("STUDIO_RENDER \(file.path)")
    }
}
