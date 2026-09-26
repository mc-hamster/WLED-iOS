import XCTest
import SwiftUI
import WebKit
import CryptoKit
@testable import WLED

/// Exercises WebKit's real custom-scheme origin and JavaScript/native bridge.
@MainActor
final class WorkspaceBrowserTests: XCTestCase {
    func testOfflineSettingsAndNativeBridgeUseSelectedDevice() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline browser fixture is isolated to Simulator")
        #endif
        let fixture = StudioPreviewFixture()
        var requests: [String] = []
        let original = fixture.device.requestAction
        fixture.device.requestAction = { method, path, body, type in
            requests.append(path)
            return try await original(method, path, body, type)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        var notices: [String] = []
        let content = DeviceWorkspaceWebView(device: fixture.device, path: "/settings", refreshID: UUID(),
            onUnlock: {}, onNotice: { notices.append($0) }, onDownload: { _ in })
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        var browser: WKWebView?
        for _ in 0..<100 {
            browser = findBrowser(host.view)
            if browser?.url?.path == "/settings", browser?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let web = try XCTUnwrap(browser)
        let title = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(title.contains("LED"), "Settings menu failed to load: \(title.prefix(120))")
        // DOM readiness can precede the first composited WebKit frame.
        // Retry the render only; never retry a controller command.
        var image: UIImage?
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(200))
            let candidate = try await web.takeSnapshot(configuration: nil)
            if hasRenderedContent(candidate) { image = candidate; break }
        }
        let rendered = try XCTUnwrap(image, "WebKit did not render a nonempty settings page")
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "09-offline-device-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("StudioRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("09-offline-device-settings.png")
        try XCTUnwrap(rendered.pngData()).write(to: file)
        print("STUDIO_RENDER \(file.path)")
        let bridge = try await web.callAsyncJavaScript("const r = await fetch('/json/si'); return JSON.stringify({status:r.status, body:await r.json()});", arguments: [:], in: nil, contentWorld: .page) as? String
        let response = try XCTUnwrap(bridge).data(using: .utf8)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? Int, 200)
        XCTAssertNotNil((parsed["body"] as? [String: Any])?["state"])
        XCTAssertTrue(requests.contains("/json/si"))
        XCTAssertTrue(notices.isEmpty, notices.joined(separator: "; "))

        let xhr = try await web.callAsyncJavaScript("return await new Promise((resolve,reject)=>{let x=new XMLHttpRequest();x.open('GET','/json/effects');x.onload=()=>resolve(x.responseText);x.onerror=reject;x.send();});", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertTrue(xhr?.contains("Breathe") == true)
        XCTAssertTrue(requests.contains("/json/effects"))

        web.load(URLRequest(url: try XCTUnwrap(URL(string: "wled-local://device/settings/leds"))))
        for _ in 0..<100 {
            if web.url?.path == "/settings/leds", !web.isLoading,
               (try? await web.evaluateJavaScript("typeof GetV")) as? String == "function" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let script = try await web.evaluateJavaScript("typeof GetV") as? String
        XCTAssertEqual(script, "function")
        XCTAssertTrue(requests.contains(where: { $0.hasPrefix("/settings/s.js") }))
        XCTAssertTrue(notices.isEmpty, notices.joined(separator: "; "))

        for (path, function) in [("/cpal.htm", "upload"), ("/pixart.htm", "postPixels")] {
            web.load(URLRequest(url: try XCTUnwrap(URL(string: "wled-local://device" + path))))
            for _ in 0..<100 {
                if web.url?.path == path, !web.isLoading,
                   (try? await web.evaluateJavaScript("typeof " + function)) as? String == "function" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let script = try await web.evaluateJavaScript("typeof " + function) as? String
            XCTAssertEqual(script, "function", "Offline tool scripts did not execute: " + path)
            if path == "/cpal.htm" {
                let encoding = try await web.evaluateJavaScript("document.characterSet") as? String
                let banner = try await web.evaluateJavaScript("document.getElementById('devBanner').textContent") as? String
                XCTAssertEqual(encoding?.uppercased(), "UTF-8")
                XCTAssertEqual(banner, "⚠ DEVELOPMENT BUILD — WORK IN PROGRESS — NOT FOR PRODUCTION USE")
            }
        }

        // SwiftUI controls its representable's frame. Keep the hosting owner
        // (and coordinator) alive while using plain UIKit sizing for the
        // narrow-screen regressions below.
        let viewport = UIView(frame: window.bounds)
        window.addSubview(viewport)
        web.removeFromSuperview()
        viewport.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = true
        web.autoresizingMask = []
        web.load(URLRequest(url: try XCTUnwrap(URL(string: "wled-local://device/"))))
        for _ in 0..<100 {
            if web.url?.path == "/", !web.isLoading,
               (try? await web.evaluateJavaScript("typeof openTab")) as? String == "function" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await web.evaluateJavaScript("openTab(1)")
        for width in [440, 320] {
            web.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: 850)
            try await Task.sleep(for: .milliseconds(300))
            try await assertFullControlLayout(web, width: width)
        }

        // Uploaded pages must load their own dependencies even when their names
        // collide with packaged WLED assets. Missing dependencies may use the bundle.
        let controllerFiles = [
            "/index.htm": Data("<html><head><link rel='stylesheet' href='style.css'><script src='common.js'></script><script src='iro.js'></script></head><body><main id='controller' class='controller-test'>Controller page</main></body></html>".utf8),
            "/common.js": Data("window.controllerScript = 'selected device';".utf8),
            "/style.css": Data(".controller-test { padding-left: 37px; }".utf8)
        ]
        var fileReads = Set<String>()
        fixture.device.requestAction = { method, path, body, type in
            if path == "/ble/fs", let input = try JSONSerialization.jsonObject(with: body) as? [String: Any],
               input["op"] as? String == "read", let file = input["path"] as? String {
                fileReads.insert(file)
                if let bytes = controllerFiles[file] {
                    let offset = input["offset"] as? Int ?? 0
                    let count = min(input["length"] as? Int ?? 1024, bytes.count - offset)
                    return try .json(["success": true, "path": file, "size": bytes.count, "offset": offset,
                        "next": offset + count, "eof": offset + count == bytes.count,
                        "revision": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                        "data": bytes.subdata(in: offset..<(offset + count)).base64EncodedString()])
                }
            }
            return try await original(method, path, body, type)
        }
        web.load(URLRequest(url: try XCTUnwrap(URL(string: "wled-local://device/index.htm?deviceFile=1"))))
        for _ in 0..<100 {
            if !web.isLoading,
               (try? await web.evaluateJavaScript("window.controllerScript")) as? String == "selected device" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let customScript = try await web.evaluateJavaScript("window.controllerScript") as? String
        let customStyle = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('controller')).paddingLeft") as? String
        let fallbackLibrary = try await web.evaluateJavaScript("typeof iro") as? String
        let dependencies = try await web.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('script[src],link[href]')].map(e=>e.src||e.href))") as? String ?? ""
        let context = "URL: \(web.url?.absoluteString ?? "none"); file reads: \(fileReads.sorted()); dependencies: \(dependencies)"
        XCTAssertEqual(web.url?.host, "files", context)
        XCTAssertEqual(customScript, "selected device", context)
        XCTAssertEqual(customStyle, "37px", context)
        XCTAssertNotEqual(fallbackLibrary, "undefined")
        XCTAssertTrue(fileReads.isSuperset(of: ["/index.htm", "/common.js", "/style.css", "/iro.js"]))
        XCTAssertFalse(fileReads.contains("/native.css"))
        XCTAssertTrue(notices.isEmpty, notices.joined(separator: "; "))
        web.load(URLRequest(url: try XCTUnwrap(URL(string: "wled-local://files/"))))
        for _ in 0..<100 {
            if web.url?.path == "/", !web.isLoading,
               (try? await web.evaluateJavaScript("window.controllerScript")) as? String == "selected device" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let customHome = try await web.evaluateJavaScript("window.controllerScript") as? String
        XCTAssertEqual(customHome, "selected device", "Custom-page home links must retain the controller index")
    }

    private func assertFullControlLayout(_ web: WKWebView, width: Int) async throws {
        let result = try await web.callAsyncJavaScript("""
            await document.fonts.ready;
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const banner = document.getElementById('devBanner').getBoundingClientRect();
            const header = document.getElementById('top'), bounds = header.getBoundingClientRect();
            const content = document.querySelector('.container').getBoundingClientRect();
            const footer = document.getElementById('bot').getBoundingClientRect();
            const field = document.querySelector('#fxFind input'), search = field.getBoundingClientRect();
            const icon = document.querySelector('#fxFind .search-icon').getBoundingClientRect();
            const buttons = [...header.querySelectorAll('.btnwrap > button')].filter(button => button.getBoundingClientRect().width > 0);
            return {width: innerWidth, bannerBottom: banner.bottom, headerTop: bounds.top,
                headerBottom: bounds.bottom, contentTop: content.top, contentBottom: content.bottom, footerTop: footer.top,
                searchTextStart: search.left + parseFloat(getComputedStyle(field).paddingLeft), iconRight: icon.right,
                buttonCount: buttons.length, labelsFit: buttons.every(button => {
                    const rect = button.getBoundingClientRect(), label = button.querySelector('.tab-label');
                    return rect.left >= bounds.left && rect.right <= bounds.right + 1 && (!label || label.scrollWidth <= label.clientWidth + 1);
                })};
            """, arguments: [:], in: nil, contentWorld: .page)
        let geometry = try XCTUnwrap(result as? [String: Any])
        func number(_ key: String) throws -> Double { try XCTUnwrap(geometry[key] as? Double, key) }
        XCTAssertEqual(try number("width"), Double(width))
        XCTAssertGreaterThanOrEqual(try number("headerTop"), try number("bannerBottom") - 1)
        XCTAssertGreaterThanOrEqual(try number("contentTop"), try number("headerBottom") - 1)
        XCTAssertLessThanOrEqual(try number("contentBottom"), try number("footerTop") + 1)
        XCTAssertGreaterThanOrEqual(try number("searchTextStart"), try number("iconRight") + 4)
        XCTAssertGreaterThanOrEqual(try number("buttonCount"), 6)
        XCTAssertEqual(geometry["labelsFit"] as? Bool, true, "Toolbar text must fit every visible button: \(geometry)")
    }

    private func hasRenderedContent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, cg.bitsPerPixel >= 24,
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let stride = cg.bitsPerPixel / 8
        var colors = Set<UInt32>()
        // Compare whole pixel colors, not PNG size (uniform snapshots can be large).
        for row in Swift.stride(from: 0, to: cg.height, by: max(1, cg.height / 48)) {
            for column in Swift.stride(from: 0, to: cg.width, by: max(1, cg.width / 48)) {
                let offset = row * cg.bytesPerRow + column * stride
                colors.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
                if colors.count > 8 { return true }
            }
        }
        return false
    }

    private func findBrowser(_ view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findBrowser($0) }.first
    }
}
