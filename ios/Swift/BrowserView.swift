//  BrowserView.swift — in-app I2P browser.
//
//  WKWebView loads pages through two custom URL schemes (i2p-http / i2p-https);
//  I2pdSchemeHandler fetches each request through the local i2pd HTTP proxy at
//  127.0.0.1:<httpproxy port>, so *.i2p sites work without installing the
//  mobileconfig profile.

import SwiftUI
import WebKit

final class BrowserModel: ObservableObject {
    let handler = I2pdSchemeHandler()

    var webView: WKWebView?
    @Published var address = ""
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var alertMessage: String?

    var alertBinding: Binding<Bool> {
        Binding(
            get: { self.alertMessage != nil },
            set: { if !$0 { self.alertMessage = nil } }
        )
    }

    func go() {
        guard I2pdCore.routerRunning else {
            alertMessage = "Start the router (Router tab) before browsing."
            return
        }
        let raw = address.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        var url = URL(string: raw)
        if url?.scheme == nil { url = URL(string: "http://" + raw) }
        guard let url = url else { return }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = (scheme == "https") ? "i2p-https" : "i2p-http"
            if let target = comps?.url {
                webView?.load(URLRequest(url: target))
            }
        } else if scheme?.hasPrefix("i2p-") == true {
            webView?.load(URLRequest(url: url))
        }
    }

    func updateAddress(_ url: URL?) {
        guard let url = url else { return }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.scheme == "i2p-https" { comps?.scheme = "https" }
        else if url.scheme == "i2p-http" { comps?.scheme = "http" }
        address = comps?.string ?? url.absoluteString
    }
}

struct I2pWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(model.handler, forURLScheme: "i2p-http")
        config.setURLSchemeHandler(model.handler, forURLScheme: "i2p-https")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        model.webView = web
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: I2pWebView

        init(_ parent: I2pWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let targetFrame = navigationAction.targetFrame,
                  targetFrame.isMainFrame else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.scheme = (scheme == "https") ? "i2p-https" : "i2p-http"
                if let rewritten = comps?.url {
                    DispatchQueue.main.async {
                        webView.load(URLRequest(url: rewritten))
                    }
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.model.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.model.loading = false
            parent.model.updateAddress(webView.url)
            parent.model.canGoBack = webView.canGoBack
            parent.model.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.model.loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.model.loading = false
        }
    }
}

struct BrowserView: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                addressBar
                I2pWebView(model: model)
                    .ignoresSafeArea(edges: .bottom)
                bottomBar
            }
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .alert("ios2pd", isPresented: model.alertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.alertMessage ?? "")
            }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("example.i2p", text: $model.address)
                .font(.system(size: 15))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { model.go() }
            if model.loading {
                ProgressView()
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .modifier(GlassPill())
        .padding(10)
    }

    private var bottomBar: some View {
        HStack(spacing: 44) {
            Button { model.webView?.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBack)

            Button { model.webView?.goForward() } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForward)

            Button { model.webView?.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }

            Button { model.go() } label: {
                Image(systemName: "arrow.right.circle.fill")
            }
        }
        .font(.title3)
        .padding(.vertical, 10)
    }
}
