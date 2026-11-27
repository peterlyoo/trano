import AppKit
import Quartz
import WebKit
import TerminalCore

@MainActor final class DeveloperLinkPreviewController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = DeveloperLinkPreviewController()
    private var panel: DeveloperPreviewPanel?
    private var monitor: Any?

    func show(_ target: QuickLookLinkTarget, owner: NSWindow) {
        let panel: DeveloperPreviewPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = DeveloperPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.minSize = NSSize(width: 400, height: 300)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.delegate = self
            self.panel = panel
        }
        if let preview = panel.contentView as? QLPreviewView { preview.close() }
        (panel.contentView as? WKWebView)?.stopLoading()
        switch target {
        case .file(let url):
            guard let preview = QLPreviewView(frame: NSRect(origin: .zero, size: panel.contentLayoutRect.size), style: .normal) else { return }
            preview.autoresizingMask = [.width, .height]
            preview.shouldCloseWithWindow = true
            preview.previewItem = url as NSURL
            panel.title = url.lastPathComponent
            panel.contentView = preview
        case .web(let url):
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let web = WKWebView(frame: NSRect(origin: .zero, size: panel.contentLayoutRect.size), configuration: configuration)
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            web.underPageBackgroundColor = .windowBackgroundColor
            panel.title = url.host ?? "Link Preview"
            panel.contentView = web
            web.load(URLRequest(url: url))
        }
        let frame = owner.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        panel.makeKeyAndOrderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, let panel = self.panel, panel.isVisible else { return event }
                if event.type == .keyDown {
                    if event.window === panel, event.keyCode == 53, (panel.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
                        self.close(); return nil
                    }
                    return event
                }
                if event.window !== panel { self.close() }
                return event
            }
        }
    }

    func close() {
        (panel?.contentView as? WKWebView)?.stopLoading()
        panel?.close()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    func windowWillClose(_ notification: Notification) {
        (panel?.contentView as? WKWebView)?.stopLoading()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let host = url.host, !host.isEmpty,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
}

@MainActor private final class DeveloperPreviewPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() }
        else { super.keyDown(with: event) }
    }
}
