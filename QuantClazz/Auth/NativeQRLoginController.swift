import Combine
import Foundation
import UIKit
import WebKit

@MainActor
final class NativeQRLoginController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Phase { case loading, ready, validating, expired, failed, verification }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var message = "正在获取二维码…"
    @Published var showOfficialVerification = false
    let webView: WKWebView
    private var bridge: QRBridge?
    private var session: AppSession?
    private var active = false
    private var generation = 0
    private var submittedToken: String?
    private var validationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = AppSession.loginStore
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        let proxy = QRBridge()
        config.userContentController.add(proxy, name: "nativeQR")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        bridge = proxy
        super.init()
        proxy.owner = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func start(session: AppSession) {
        guard !active else { return }
        self.session = session
        if let bridge {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "nativeQR")
            webView.configuration.userContentController.add(bridge, name: "nativeQR")
        }
        active = true
        refresh()
    }

    func refresh() {
        guard active else { return }
        generation += 1
        validationTask?.cancel()
        timeoutTask?.cancel()
        submittedToken = nil
        qrImage = nil
        phase = .loading
        message = "正在获取二维码…"
        session?.authError = nil
        webView.configuration.userContentController.removeAllUserScripts()
        let script = Self.bridgeScript.replacingOccurrences(of: "__NATIVE_EPOCH__", with: String(generation))
        webView.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView.load(URLRequest(url: URL(string: "https://bbs.quantclass.cn/user/wechat?preurl=%2F")!))
        let request = generation
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.active, self.generation == request, self.phase == .loading else { return }
            self.phase = .failed
            self.message = "二维码加载失败，请重试"
        }
    }

    func stop() {
        active = false
        generation += 1
        validationTask?.cancel()
        timeoutTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nativeQR")
        webView.configuration.userContentController.removeAllUserScripts()
        webView.stopLoading()
        // Navigating away destroys both official polling and all bridge timers.
        webView.loadHTMLString("<!doctype html><html></html>", baseURL: nil)
        session = nil
    }

    fileprivate func receive(_ event: WKScriptMessage) {
        guard active, let body = event.body as? [String: String], let kind = body["kind"], body["epoch"] == String(generation),
              let url = event.frameInfo.request.url else { return }
        guard url.user == nil, url.password == nil, url.scheme == "https" else { return }
        let origin = event.frameInfo.securityOrigin
        guard origin.protocol == "https", origin.port == 0 || origin.port == 443 else { return }
        if event.frameInfo.isMainFrame, origin.host == "bbs.quantclass.cn", Self.trustedForum(url), kind == "token" {
            guard let token = body["value"], !token.isEmpty, token.count < 32_768,
                  submittedToken != token, let session else { return }
            submittedToken = token
            phase = .validating
            message = "正在验证登录…"
            let request = generation
            validationTask = Task { [weak self] in
                await session.acceptToken(token)
                guard let self, self.active, self.generation == request else { return }
                if session.token == token { self.stop() }
                else {
                    self.message = session.authError ?? "登录验证失败，请重试"
                    self.phase = self.message.contains("网站要求完成验证") ? .verification : .failed
                }
            }
        } else if !event.frameInfo.isMainFrame, origin.host == "api.quantclass.cn",
                  url.host == origin.host, url.path == "/user/login-page" {
            if kind == "qr", let value = body["value"], value.hasPrefix("data:image/png;base64,"), value.count < 1_500_000,
               let data = Data(base64Encoded: String(value.dropFirst("data:image/png;base64,".count))),
               let image = UIImage(data: data), image.size.width >= 100, image.size.width <= 1024 {
                guard phase != .validating else { return }
                qrImage = image
                phase = .ready
                message = "扫码后，请在微信确认登录"
                timeoutTask?.cancel()
            } else if kind == "expired", phase != .validating {
                phase = .expired
                message = "二维码已过期"
            }
        } else if event.frameInfo.isMainFrame, origin.host == "bbs.quantclass.cn", kind == "verification" {
            phase = .verification
            message = "需要完成官网验证"
        }
    }

    static func trustedForum(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "bbs.quantclass.cn" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard active else { decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel); return }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if Self.trustedForum(url) || (action.targetFrame?.isMainFrame == false && url.scheme == "https" && url.host == "api.quantclass.cn" && (url.port == nil || url.port == 443)) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            phase = .verification
            message = "需要完成官网验证"
            if showOfficialVerification, action.navigationType == .linkActivated, url.scheme == "https" { UIApplication.shared.open(url) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard active else { return }
        phase = .failed; message = "登录页面已中断，请重试"
    }
    private func fail(_ error: Error) {
        guard active, (error as NSError).code != NSURLErrorCancelled else { return }
        phase = .failed; message = "连接官网失败，请重试"
    }

    private static let bridgeScript = """
    (() => {
      const forum = window === window.top && location.origin === 'https://bbs.quantclass.cn';
      const qrPage = window !== window.top && location.origin === 'https://api.quantclass.cn' && location.pathname === '/user/login-page';
      if (!forum && !qrPage) return;
      const send = (kind, value = '') => window.webkit.messageHandlers.nativeQR.postMessage({kind, value, epoch: "__NATIVE_EPOCH__"});
      let last = '', ended = false;
      const tick = () => {
        if (ended) return;
        if (forum) {
          if (location.pathname.replace(new RegExp('/$'), '') === '/user/wechat' && document.head && document.body) {
            let viewport = document.querySelector('meta[name="viewport"]');
            if (!viewport) { viewport = document.createElement('meta'); viewport.name = 'viewport'; document.head.appendChild(viewport); }
            viewport.content = 'width=device-width,initial-scale=1';
            let style = document.getElementById('native-login-fit');
            if (!style) {
              style = document.createElement('style'); style.id = 'native-login-fit';
              style.textContent = 'html,body{min-width:0!important;width:100%!important;overflow-x:hidden!important}.register{width:100%!important;max-width:420px!important;min-width:0!important;margin:16px auto!important;padding:0 8px!important;box-sizing:border-box!important}.register-select,.quick,.quick-container,.register .el-tabs__content,.register .el-tab-pane{width:100%!important;max-width:100%!important;min-width:0!important;margin-left:0!important;margin-right:0!important;padding-left:0!important;padding-right:0!important;box-sizing:border-box!important}';
              document.head.appendChild(style);
            }
            const login = document.querySelector('.register');
            for (let node = login && login.parentElement; node && node !== document.body; node = node.parentElement) {
              node.style.setProperty('min-width','0','important'); node.style.setProperty('width','100%','important'); node.style.setProperty('max-width','100%','important'); node.style.setProperty('box-sizing','border-box','important');
            }
          }
          const token = localStorage.getItem('access_token');
          if (token && token !== last) { last = token; send('token', token); }
          if (!location.pathname.replace(new RegExp('/$'), '').startsWith('/user/wechat') && !token && /captcha|verify|verification/.test(location.pathname)) send('verification');
        } else {
          const image = document.querySelector('#qr img');
          const canvas = document.querySelector('#qr canvas');
          const value = image && image.src.startsWith('data:image/png;base64,') ? image.src : canvas ? canvas.toDataURL('image/png') : '';
          if (value && value !== last) { last = value; send('qr', value); }
          const refresh = document.getElementById('refresh');
          if (refresh && getComputedStyle(refresh).display !== 'none') { ended = true; send('expired'); }
        }
      };
      const timer = setInterval(() => { try { tick(); } catch (_) {} }, 1000);
      setTimeout(() => { clearInterval(timer); }, 6 * 60 * 1000);
      addEventListener('pagehide', () => clearInterval(timer), {once:true});
    })();
    """
}

private final class QRBridge: NSObject, WKScriptMessageHandler {
    weak var owner: NativeQRLoginController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { owner?.receive(message) }
    }
}
