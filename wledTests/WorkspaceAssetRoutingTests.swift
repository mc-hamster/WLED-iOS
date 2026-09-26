import Foundation
import Testing
@testable import WLED

@MainActor
struct WorkspaceAssetRoutingTests {
    @Test func textualResponsesDeclareEncodingWithoutChangingBinaryOrExplicitCharsets() {
        for mime in ["text/html", "text/css", "text/plain", "application/javascript", "application/json", "image/svg+xml"] {
            #expect(DeviceWorkspaceWebView.responseContentType(mime) == mime + "; charset=utf-8")
        }
        #expect(DeviceWorkspaceWebView.responseContentType("text/html; charset=iso-8859-1") == "text/html; charset=iso-8859-1")
        #expect(DeviceWorkspaceWebView.responseContentType("image/png") == "image/png")
        #expect(DeviceWorkspaceWebView.responseContentType("font/woff2") == "font/woff2")
    }

    @Test func workspaceRegistersNativeNavigationAndDialogCallbacks() {
        let fixture = StudioPreviewFixture()
        let view = DeviceWorkspaceWebView(device: fixture.device, path: "/settings", refreshID: UUID(),
                                         onUnlock: {}, onNotice: { _ in }, onDownload: { _ in })
        let coordinator = view.makeCoordinator()
        for selector in ["webView:decidePolicyForNavigationAction:decisionHandler:",
                         "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
                         "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
                         "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:"] {
            #expect(coordinator.responds(to: NSSelectorFromString(selector)))
        }
    }

    @Test func bundledToolsSupportFirmwareLinksAndNativeDestinations() throws {
        let root = try #require(Bundle.main.resourceURL?.appendingPathComponent("DeviceWorkspace.bundle"))
        for tool in ["cpal", "pixart", "pxmagic", "pixelforge"] {
            for path in ["/\(tool)", "/\(tool).htm", "/\(tool)/"] {
                let relative = try #require(DeviceWorkspaceWebView.bundledPath(for: path))
                #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))
            }
        }
        #expect(DeviceWorkspaceWebView.bundledPath(for: "/settings/common.js") == "common.js")
        #expect(DeviceWorkspaceWebView.bundledPath(for: "/pixelforge/omggif.js") == "pixelforge/omggif.js")
    }

    @Test func dynamicSettingsAndFilesystemResourcesAreNotReplacedByStaticPages() {
        #expect(DeviceWorkspaceWebView.bundledPath(for: "/settings/s.js") == "settings/s.js")
        #expect(DeviceWorkspaceWebView.bundledPath(for: "/palette0.json") == "palette0.json")
        #expect(DeviceWorkspaceWebView.bundledPath(for: "/../cfg.json") == nil)
    }
}
