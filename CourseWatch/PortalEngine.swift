import Foundation
import WebKit

enum PortalError: LocalizedError {
    case pageLoad
    case crawlerMissing
    case invalidResponse
    var errorDescription: String? {
        switch self {
        case .pageLoad: "教学网页面无法打开"
        case .crawlerMissing: "程序缺少网页读取组件"
        case .invalidResponse: "教学网返回了无法识别的数据"
        }
    }
}

@MainActor final class PortalEngine: NSObject, WKNavigationDelegate {
    private let portal = URL(string: "https://course.pku.edu.cn/webapps/portal/execute/tabs/tabAction?tab_tab_group_id=_1_1")!
    private let campusLogin = URL(string: "https://course.pku.edu.cn/webapps/bb-sso-BBLEARN/login.html")!
    private let webView: WKWebView
    private var hostWindow: NSWindow?
    private var pageContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func crawl(selectedCourseIDs: [String]) async throws -> CrawlResult {
        let first = try await crawlOnce(selectedCourseIDs: selectedCourseIDs)
        guard first.loginRequired, let credentials = CredentialsVault.load(),
              await automaticLogin(credentials) else { return first }
        return try await crawlOnce(selectedCourseIDs: selectedCourseIDs)
    }

    private func crawlOnce(selectedCourseIDs: [String]) async throws -> CrawlResult {
        keepWebViewActive()
        try await load(portal)
        guard let file = Bundle.main.url(forResource: "Crawler", withExtension: "js"),
              let script = try? String(contentsOf: file, encoding: .utf8) else {
            throw PortalError.crawlerMissing
        }
        let output = try await evaluate(script, arguments: ["selectedIds": selectedCourseIDs])
        guard let json = output as? String, let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(CrawlResult.self, from: data) else {
            throw PortalError.invalidResponse
        }
        return result
    }

    private func keepWebViewActive() {
        guard hostWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 30, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.contentView = webView
        window.orderFront(nil)
        hostWindow = window
    }

    private func automaticLogin(_ credentials: LoginCredentials) async -> Bool {
        do {
            try await load(campusLogin)
            var ready = false
            for _ in 0..<30 {
                if webView.url?.host == "iaaa.pku.edu.cn", !webView.isLoading,
                   let value = try? await evaluate("return !!document.getElementById('user_name') && typeof crypt !== 'undefined' && crypt !== null;"),
                   value as? Bool == true {
                    ready = true; break
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard ready else { return false }
            let script = """
            const hidden = id => { const node = document.getElementById(id); return node && getComputedStyle(node).display === 'none'; };
            if (!hidden('code_area') || !hidden('sms_area') || !hidden('otp_area')) return false;
            const account = document.getElementById('user_name');
            const secret = document.getElementById('password');
            if (!account || !secret || typeof oauthLogon !== 'function') return false;
            account.value = username; secret.value = password;
            account.dispatchEvent(new Event('change', { bubbles: false }));
            oauthLogon();
            return true;
            """
            guard let submitted = try await evaluate(script, arguments: ["username": credentials.username,
                                                                           "password": credentials.password]) as? Bool,
                  submitted else { return false }
            for _ in 0..<30 {
                if webView.url?.host == "course.pku.edu.cn", !webView.isLoading { return true }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch { }
        return false
    }

    private func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pageContinuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: 30))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageContinuation?.resume()
        pageContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageContinuation?.resume(throwing: error)
        pageContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageContinuation?.resume(throwing: error)
        pageContinuation = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "http", url.host == "course.pku.edu.cn",
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if let secureURL = components.url {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: secureURL))
                return
            }
        }
        decisionHandler(.allow)
    }
}
