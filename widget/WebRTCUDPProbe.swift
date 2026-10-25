import Foundation
import WebKit

// A fresh, nonpersistent, windowless WebKit context for each widget refresh.
// It loads only this bundled script; it never loads the remote page or analytics.
@MainActor
final class WebRTCUDPProbe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<WebRTCUDPStatus, Never>?
    private var timeout: Task<Void, Never>?
    private var claudeIP: String?

    static func measure(claudeIP: String?) async -> WebRTCUDPStatus {
        let probe = WebRTCUDPProbe()
        return await probe.run(claudeIP: claudeIP)
    }

    private func run(claudeIP: String?) async -> WebRTCUDPStatus {
        self.claudeIP = claudeIP
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            // A widget host has no visible window. Keep this short-lived page
            // running until ICE completes instead of suspending it as inactive.
            configuration.preferences.inactiveSchedulingPolicy = .none
            configuration.userContentController.add(self, name: "udpCandidates")
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            view.navigationDelegate = self
            webView = view
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                self?.finish(WebRTCUDPStatus(kind: .unavailable), diagnostic: "native-timeout")
            }
            view.loadHTMLString("<!doctype html><meta charset='utf-8'><script>" + Self.script + "</script>",
                                baseURL: URL(string: "https://ip.net.coffee/"))
        }
    }

    private func finish(_ result: WebRTCUDPStatus, diagnostic: String? = nil) {
        guard let completion = continuation else { return }
        if let diagnostic { NSLog("WidgetWebRTC %@", diagnostic) }
        continuation = nil
        timeout?.cancel(); timeout = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "udpCandidates")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        completion.resume(returning: result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "udpCandidates", message.frameInfo.isMainFrame,
              let payload = message.body as? [String: Any] else { return }
        guard payload["available"] as? Bool == true,
              let candidates = payload["candidates"] as? [String], candidates.count <= 128,
              candidates.allSatisfy({ $0.count <= 128 }) else {
            let reason = payload["reason"] as? String ?? "invalid-message"
            finish(WebRTCUDPStatus(kind: .unavailable), diagnostic: reason); return
        }
        finish(WebRTCUDPStatus.classify(candidates: candidates, claudeIP: claudeIP))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(WebRTCUDPStatus(kind: .unavailable), diagnostic: "navigation-\((error as NSError).code)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(WebRTCUDPStatus(kind: .unavailable), diagnostic: "provisional-\((error as NSError).code)")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(WebRTCUDPStatus(kind: .unavailable), diagnostic: "web-process-terminated")
    }

    // Same two STUN servers, 5-second collection, IPv4/IPv6 extraction and
    // public-IPv4 comparison as /claude/claude-page.js (20260916a).
    private static let script = #"""
    (async function () {
      const candidates = new Set();
      let pc, timer, finished = false;
      function complete(available, reason) {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        try { if (pc) pc.close(); } catch (_) {}
        window.webkit.messageHandlers.udpCandidates.postMessage({ available, reason: reason || '', candidates: [...candidates] });
      }
      try {
        if (typeof RTCPeerConnection !== 'function') { complete(false, 'api-unavailable'); return; }
        pc = new RTCPeerConnection({ iceServers: [
          { urls: 'stun:stun.l.google.com:19302' },
          { urls: 'stun:stun.cloudflare.com:3478' }
        ] });
        pc.onicecandidate = function (event) {
          if (!event.candidate) { complete(true); return; }
          const value = event.candidate.candidate;
          const v4 = value.match(/([0-9]{1,3}\.){3}[0-9]{1,3}/);
          if (v4 && !v4[0].startsWith('0.') && !v4[0].startsWith('127.') && v4[0] !== '0.0.0.0') candidates.add(v4[0]);
          const v6 = value.match(/([a-f0-9]{1,4}:){2,7}[a-f0-9]{1,4}/i);
          if (v6) candidates.add(v6[0]);
        };
        timer = setTimeout(function () { complete(true); }, 5000);
        pc.createDataChannel('');
        await pc.setLocalDescription(await pc.createOffer());
      } catch (error) { complete(false, error.name || 'webrtc-error'); }
    })();
    """#
}
