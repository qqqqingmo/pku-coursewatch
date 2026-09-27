import Foundation
import WebKit

@MainActor final class ExternalEngine: NSObject, WKNavigationDelegate {
    private let classView: WKWebView
    private let gradescopeView: WKWebView
    private var hostWindows: [NSWindow] = []
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    override init() {
        let classConfiguration = WKWebViewConfiguration()
        classConfiguration.websiteDataStore = .default()
        classView = WKWebView(frame: .zero, configuration: classConfiguration)
        let gradescopeConfiguration = WKWebViewConfiguration()
        gradescopeConfiguration.websiteDataStore = .default()
        gradescopeView = WKWebView(frame: .zero, configuration: gradescopeConfiguration)
        super.init()
        classView.navigationDelegate = self
        gradescopeView.navigationDelegate = self
    }

    func crawlClass(courses: [Course]) async throws -> ExternalCrawlResult {
        keepWebViewActive(classView)
        try await load(URL(string: "https://class.pku.edu.cn/")!, in: classView)
        if !(await hasClassToken()) {
            try await load(URL(string: "https://class.pku.edu.cn/login/iaaa")!, in: classView)
            if let credentials = CredentialsVault.load() {
                await finishCampusLogin(credentials)
            }
            for _ in 0..<40 {
                if await hasClassToken() { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard await hasClassToken() else {
            return ExternalCrawlResult(loginRequired: true, scanComplete: false, entries: [], warnings: [])
        }
        guard let file = Bundle.main.url(forResource: "ClassCrawler", withExtension: "js"),
              let script = try? String(contentsOf: file, encoding: .utf8) else {
            throw PortalError.crawlerMissing
        }
        let targets = courses.map { ["id": $0.id, "name": $0.name] }
        let output = try await evaluate(script, arguments: ["targets": targets], in: classView)
        guard let json = output as? String, let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(ExternalCrawlResult.self, from: data) else {
            throw PortalError.invalidResponse
        }
        return result
    }

    private func finishCampusLogin(_ credentials: LoginCredentials) async {
        for _ in 0..<30 {
            if classView.url?.host == "iaaa.pku.edu.cn", !classView.isLoading,
               let ready = try? await evaluate("return !!document.getElementById('user_name') && typeof crypt !== 'undefined' && crypt !== null;", in: classView) as? Bool,
               ready {
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
                _ = try? await evaluate(script, arguments: ["username": credentials.username,
                                                             "password": credentials.password], in: classView)
                return
            }
            if await hasClassToken() { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func crawlGradescope(course: Course, gradescopeCourseID: String) async throws -> ExternalCrawlResult {
        keepWebViewActive(gradescopeView)
        try await load(URL(string: "https://www.gradescope.com/")!, in: gradescopeView)
        let first = try await run("GradescopeCrawler", in: gradescopeView, course: course,
                                  gradescopeCourseID: gradescopeCourseID)
        guard first.loginRequired, let credentials = CredentialsVault.loadGradescope(),
              await automaticGradescopeLogin(credentials, gradescopeCourseID: gradescopeCourseID) else { return first }
        return try await run("GradescopeCrawler", in: gradescopeView, course: course,
                             gradescopeCourseID: gradescopeCourseID)
    }

    private func keepWebViewActive(_ view: WKWebView) {
        guard view.window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 30, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.contentView = view
        window.orderFront(nil)
        hostWindows.append(window)
    }

    private func automaticGradescopeLogin(_ credentials: LoginCredentials, gradescopeCourseID: String) async -> Bool {
        do {
            try await load(URL(string: "https://www.gradescope.com/login")!, in: gradescopeView)
            guard gradescopeView.url?.host == "www.gradescope.com" else { return false }
            let script = """
            if (location.origin !== 'https://www.gradescope.com') return false;
            const email = document.getElementById('session_email');
            const passwordInput = document.getElementById('session_password');
            const form = email?.closest('form');
            if (!email || !passwordInput || !form || new URL(form.action).pathname !== '/login') return false;
            const visible = element => element && getComputedStyle(element).display !== 'none';
            if ([...document.querySelectorAll('iframe[src*="captcha"], input[name*="captcha"]')].some(visible)) return false;
            email.value = username;
            passwordInput.value = password;
            const remember = document.getElementById('session_remember_me');
            if (remember) remember.checked = true;
            email.dispatchEvent(new Event('input', { bubbles: true }));
            passwordInput.dispatchEvent(new Event('input', { bubbles: true }));
            form.requestSubmit();
            return true;
            """
            guard let submitted = try await evaluate(script, arguments: ["username": credentials.username,
                                                                           "password": credentials.password], in: gradescopeView) as? Bool,
                  submitted else { return false }
            for _ in 0..<30 {
                if gradescopeView.url?.host == "www.gradescope.com", !gradescopeView.isLoading,
                   let authenticated = try? await evaluate("const response = await fetch('/courses/' + gradescopeCourseID, { credentials: 'same-origin', cache: 'no-store' }); if (!response.ok) return false; const doc = new DOMParser().parseFromString(await response.text(), 'text/html'); return !!doc.querySelector('#assignments-student-table');", arguments: ["gradescopeCourseID": gradescopeCourseID], in: gradescopeView) as? Bool,
                   authenticated { return true }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch { }
        return false
    }

    private func hasClassToken() async -> Bool {
        guard classView.url?.host == "class.pku.edu.cn", !classView.isLoading else { return false }
        let token = try? await evaluate("return !!localStorage.getItem('token');", in: classView) as? Bool
        return token == true
    }

    private func run(_ name: String, in view: WKWebView, course: Course,
                     gradescopeCourseID: String? = nil) async throws -> ExternalCrawlResult {
        guard let file = Bundle.main.url(forResource: name, withExtension: "js"),
              let script = try? String(contentsOf: file, encoding: .utf8) else {
            throw PortalError.crawlerMissing
        }
        var arguments: [String: Any] = ["courseId": course.id, "courseName": course.name]
        if let gradescopeCourseID { arguments["gradescopeCourseID"] = gradescopeCourseID }
        let output = try await evaluate(script, arguments: arguments, in: view)
        guard let json = output as? String, let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(ExternalCrawlResult.self, from: data) else {
            throw PortalError.invalidResponse
        }
        return result
    }

    private func evaluate(_ script: String, arguments: [String: Any] = [:], in view: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func load(_ url: URL, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations[ObjectIdentifier(view)] = continuation
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuations.removeValue(forKey: ObjectIdentifier(webView))?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuations.removeValue(forKey: ObjectIdentifier(webView))?.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuations.removeValue(forKey: ObjectIdentifier(webView))?.resume(throwing: error)
    }
}
