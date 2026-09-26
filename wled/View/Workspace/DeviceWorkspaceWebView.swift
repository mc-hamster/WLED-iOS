import SwiftUI
@preconcurrency import WebKit

struct WorkspaceDownload: Identifiable {
    let id = UUID()
    let url: URL
}

struct DeviceWorkspaceWebView: UIViewRepresentable {
    @ObservedObject var device: DeviceWithState
    var path: String
    var refreshID: UUID
    var onUnlock: () -> Void
    var onNotice: (String) -> Void
    var onDownload: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func isWorkspaceURL(_ url: URL) -> Bool {
        url.scheme == "wled-local" && ["device", "files"].contains(url.host ?? "")
    }

    static func responseContentType(_ value: String) -> String {
        let normalized = value.lowercased()
        let mime = normalized.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
        let textual = mime.hasPrefix("text/") || ["application/javascript", "application/json", "image/svg+xml"].contains(mime)
        return textual && !normalized.contains("charset=") ? value + "; charset=utf-8" : value
    }

    static func bundledPath(for path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("..") else { return nil }
        let routes = ["/": "index.htm", "/settings": "settings.htm", "/settings/": "settings.htm",
            "/settings/wifi": "settings_wifi.htm", "/settings/leds": "settings_leds.htm", "/settings/ui": "settings_ui.htm",
            "/settings/sync": "settings_sync.htm", "/settings/time": "settings_time.htm", "/settings/sec": "settings_sec.htm",
            "/settings/dmx": "settings_dmx.htm", "/settings/um": "settings_um.htm", "/settings/2D": "settings_2D.htm",
            "/settings/pins": "settings_pininfo.htm", "/welcome": "welcome.htm", "/edit": "edit.htm",
            "/liveview": "liveview.htm", "/liveview2D": "liveviewws2D.htm", "/u": "usermod.htm", "/dmxmap": "dmxmap.htm",
            "/omggif.js": "pixelforge/omggif.js"]
        if let relative = routes[path] { return relative }
        for tool in ["cpal", "pixart", "pxmagic", "pixelforge"] {
            if path == "/\(tool)" || path == "/\(tool).htm" || path == "/\(tool)/" { return "\(tool)/\(tool).htm" }
        }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        if ["settings", "cpal", "pixelforge"].contains(directory),
           ["common.js", "style.css", "favicon.ico", "iro.js"].contains(filename) { return filename }
        if directory == "pixelforge", filename == "omggif.js" { return "pixelforge/omggif.js" }
        return String(path.dropFirst())
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "wled-local")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "workspace")
        if let script = context.coordinator.asset("bridge.js"), let source = try? String(contentsOf: script, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.063, green: 0.071, blue: 0.094, alpha: 1)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.refreshID != refreshID || context.coordinator.path != path {
            context.coordinator.refreshID = refreshID
            context.coordinator.path = path
            if let url = URL(string: "wled-local://device" + path) { view.load(URLRequest(url: url)) }
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "workspace")
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
        var parent: DeviceWorkspaceWebView
        weak var webView: WKWebView?
        var refreshID: UUID?
        var path = ""
        private var loads: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var requests: [UUID: Task<Void, Never>] = [:]

        init(_ parent: DeviceWorkspaceWebView) { self.parent = parent }

        func cancel() {
            loads.values.forEach { $0.cancel() }; loads.removeAll()
            requests.values.forEach { $0.cancel() }; requests.removeAll()
        }

        func asset(_ relative: String) -> URL? {
            guard !relative.contains(".."), !relative.hasPrefix("/") else { return nil }
            let roots = [Bundle.main.resourceURL?.appendingPathComponent("DeviceWorkspace.bundle"),
                         Bundle.main.resourceURL?.appendingPathComponent("Resources/DeviceWorkspace.bundle")]
            return roots.compactMap { $0?.appendingPathComponent(relative) }.first {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
        }

        func localAsset(for path: String) -> URL? {
            guard let relative = DeviceWorkspaceWebView.bundledPath(for: path.isEmpty ? "/" : path) else { return nil }
            return asset(relative)
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let key = ObjectIdentifier(urlSchemeTask)
            loads[key] = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let url = urlSchemeTask.request.url, DeviceWorkspaceWebView.isWorkspaceURL(url) else { throw WorkspaceError.invalidPath }
                    let response: DeviceAPIResponse
                    let deviceFile = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "deviceFile" && $0.value == "1" } == true
                    if !deviceFile, let asset = localAsset(for: url.path), !(url.path == "/edit" && url.query != nil) {
                        let bundled = { try DeviceAPIResponse(status: 200, contentType: DeviceWithState.workspaceMIME(asset.path), body: Data(contentsOf: asset)) }
                        if url.host == "files", !["/bridge.js", "/native.css"].contains(url.path) {
                            let selectedPath = url.path == "/" || url.path.isEmpty ? "/index.htm" : url.path
                            let selected = try await parent.device.workspaceRequest(path: selectedPath + (url.query.map { "?" + $0 } ?? ""))
                            response = selected.status == 404 ? try bundled() : selected
                        } else { response = try bundled() }
                    } else if url.path == "/update" || url.path == "/updatebootloader" {
                        response = DeviceAPIResponse(status: 200, contentType: "text/html", body: Data("<html><meta name='viewport' content='width=device-width'><body style='font:17px -apple-system;background:#101218;color:#eee;padding:28px'><h2>Update over USB</h2><p>This firmware uses a single application partition. Connect WLED to your computer with USB to install a firmware update.</p></body></html>".utf8))
                    } else {
                        response = try await parent.device.workspaceRequest(path: url.path + (url.query.map { "?" + $0 } ?? ""))
                    }
                    guard loads[key] != nil, !Task.isCancelled else { return }
                    if response.status == 401 { parent.onUnlock() }
                    guard let header = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: ["Content-Type": DeviceWorkspaceWebView.responseContentType(response.contentType), "Cache-Control": "no-store"]) else { throw WorkspaceError.invalidReply }
                    urlSchemeTask.didReceive(header)
                    urlSchemeTask.didReceive(response.body)
                    urlSchemeTask.didFinish()
                } catch {
                    guard loads[key] != nil, !Task.isCancelled else { return }
                    if case WorkspaceError.rejected(401, _) = error { parent.onUnlock() }
                    urlSchemeTask.didFailWithError(error)
                    parent.onNotice(error.localizedDescription)
                }
                loads[key] = nil
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            loads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.securityOrigin.protocol == "wled-local", ["device", "files"].contains(message.frameInfo.securityOrigin.host),
                  let payload = message.body as? [String: Any], let action = payload["action"] as? String else {
                replyHandler(nil, "This page cannot access the device."); return
            }
            let id = UUID()
            requests[id] = Task { [weak self] in
                guard let self else { replyHandler(nil, "Workspace closed."); return }
                defer { requests[id] = nil }
                do {
                    if action == "unlock" { parent.onUnlock(); replyHandler(["success": true], nil); return }
                    if action == "notice" {
                        parent.onNotice(String((payload["message"] as? String ?? "").prefix(400)))
                        replyHandler(["success": true], nil); return
                    }
                    let encoded = payload["body"] as? String ?? ""
                    guard encoded.utf8.count <= 24 * 1024 * 1024, let body = Data(base64Encoded: encoded) else { throw WorkspaceError.tooLarge }
                    if action == "download" {
                        let rawName = payload["name"] as? String ?? "wled-backup.json"
                        let name = URL(fileURLWithPath: rawName).lastPathComponent
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WLED-" + UUID().uuidString)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let file = directory.appendingPathComponent(name.isEmpty ? "wled-backup.json" : name)
                        try body.write(to: file, options: .atomic)
                        parent.onDownload(file); replyHandler(["success": true], nil); return
                    }
                    guard let path = payload["path"] as? String, path.hasPrefix("/"), !path.hasPrefix("//"),
                          !path.contains(".."), !path.contains("\n"), !path.contains("\r") else { throw WorkspaceError.invalidPath }
                    let result: DeviceAPIResponse
                    if action == "upload" { result = try await parent.device.workspaceUpload(path: path, data: body) }
                    else {
                        guard action == "request", let method = payload["method"] as? String,
                              ["GET", "POST", "DELETE"].contains(method) else { throw WorkspaceError.unsupported }
                        result = try await parent.device.workspaceRequest(method: method, path: path, body: body)
                    }
                    replyHandler(["status": result.status, "type": result.contentType, "body": result.body.base64EncodedString()], nil)
                    if (200..<300).contains(result.status),
                       let receipt = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
                       receipt["saved"] as? Bool == true, receipt["bluetoothEnabled"] as? Bool == false {
                        parent.onNotice("Settings saved. Bluetooth is now off. Enable it through Wi-Fi or USB to connect again.")
                        parent.device.bluetoothDisabledAction()
                    }
                } catch {
                    if case WorkspaceError.rejected(let code, let detail) = error {
                        if code == 401 { parent.onUnlock() }
                        replyHandler(["status": code, "type": "text/plain", "body": Data(detail.utf8).base64EncodedString()], nil)
                    } else { replyHandler(nil, error.localizedDescription) }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if DeviceWorkspaceWebView.isWorkspaceURL(url) {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if url.host == "device", navigationAction.targetFrame?.isMainFrame != false,
                   query.contains(where: { $0.name == "deviceFile" && $0.value == "1" }) {
                    // Isolate controller assets from already-cached bundled files.
                    // Relative scripts/styles naturally inherit this local origin.
                    var destination = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    destination?.host = "files"
                    decisionHandler(.cancel)
                    if let target = destination?.url { webView.load(URLRequest(url: target)) }
                    return
                }
                if query.contains(where: { $0.name == "func" && $0.value == "download" }) || ["/presets.json", "/cfg.json"].contains(url.path) {
                    decisionHandler(.cancel); downloadFile(url); return
                }
                decisionHandler(.allow); return
            }
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if DeviceWorkspaceWebView.isWorkspaceURL(url) {
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    if query.contains(where: { $0.name == "func" && $0.value == "download" }) { downloadFile(url) }
                    else { webView.load(URLRequest(url: url)) }
                }
                else if ["http", "https"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor () -> Void) {
            presentDialog(message: message, cancel: false) { _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (Bool) -> Void) {
            presentDialog(message: message, cancel: true, completion: completionHandler)
        }

        private func downloadFile(_ url: URL) {
            let id = UUID()
            requests[id] = Task { [weak self] in
                guard let self else { return }
                defer { requests[id] = nil }
                do {
                    let result = try await parent.device.workspaceRequest(path: url.path + (url.query.map { "?" + $0 } ?? ""))
                    try result.requireSuccess()
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let requestedPath = query.first(where: { $0.name == "path" })?.value ?? url.path
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WLED-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent(URL(fileURLWithPath: requestedPath).lastPathComponent)
                    try result.body.write(to: file, options: .atomic)
                    parent.onDownload(file)
                } catch {
                    if case WorkspaceError.rejected(401, _) = error { parent.onUnlock() }
                    else { parent.onNotice(error.localizedDescription) }
                }
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
            guard let controller = webView.window?.rootViewController else { completionHandler(nil); return }
            var presenter = controller
            while let presented = presenter.presentedViewController { presenter = presented }
            let alert = UIAlertController(title: "WLED", message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText; $0.autocapitalizationType = .none }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            presenter.present(alert, animated: true)
        }

        private func presentDialog(message: String, cancel: Bool, completion: @escaping @MainActor (Bool) -> Void) {
            guard let controller = webView?.window?.rootViewController else { completion(false); return }
            var presenter = controller
            while let presented = presenter.presentedViewController { presenter = presented }
            let alert = UIAlertController(title: "WLED", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
            if cancel { alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) }) }
            presenter.present(alert, animated: true)
        }
    }
}

struct WorkspaceShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
