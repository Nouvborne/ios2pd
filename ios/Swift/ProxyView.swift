//  ProxyView.swift — backloop.dev integration: Wi-Fi proxy profile install,
//  loopback SSL certificate refresh, keep-alive, and the web console browser.

import SwiftUI
import WebKit

struct ProxyView: View {
    @AppStorage("backloop_host") private var host = "ios2pd.backloop.dev"
    @AppStorage("backloop_https_port") private var port = 8443
    @AppStorage("backloop_ssid") private var ssid = ""
    @AppStorage("keepalive_audio") private var keepAlive = false

    @State private var busy = false
    @State private var alertMessage: String?
    @State private var sslExpiry = I2pdCore.sslExpiryString
    @State private var showConsole = false

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    private var consoleURL: URL {
        let h = host.trimmingCharacters(in: .whitespaces)
        return URL(string: "https://\(h.isEmpty ? "ios2pd.backloop.dev" : h):\(port)/")!
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Hostname")
                        Spacer()
                        TextField("ios2pd.backloop.dev", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("HTTPS port")
                        Spacer()
                        TextField("8443", value: $port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("backloop.dev proxy")
                } footer: {
                    Text("backloop.dev is a wildcard domain pointing at 127.0.0.1 with a publicly trusted certificate. The app serves HTTPS on this device so Safari can install the profile over a trusted link.")
                }

                Section {
                    HStack {
                        Text("SSID")
                        Spacer()
                        TextField("e.g. MyHomeWiFi", text: $ssid)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Detect current SSID") {
                        if let detected = I2pdCore.detectedSSID(), !detected.isEmpty {
                            ssid = detected
                        }
                    }
                } header: {
                    Text("Wi-Fi network")
                } footer: {
                    Text("iOS requires the exact SSID of the Wi-Fi you are on for the proxy profile. Enter it if it was not detected automatically.")
                }

                Section {
                    HStack {
                        Text("Certificate valid until")
                        Spacer()
                        Text(sslExpiry)
                            .foregroundStyle(.secondary)
                    }
                    Button("Update SSL servers") { refreshSsl() }
                        .disabled(busy)
                } header: {
                    Text("SSL certificate")
                } footer: {
                    Text("The loopback certificate is refreshed weekly by backloop.dev. Update it if the certificate has expired.")
                }

                Section {
                    Button("Install proxy profile (.mobileconfig)") { installProfile() }
                        .disabled(busy)
                } header: {
                    Text("Proxy profile")
                } footer: {
                    Text("Installs a Wi-Fi profile that routes HTTP/HTTPS through the local i2pd proxy (start the router first). Requires Wi-Fi; i2pd must keep running while you browse.")
                }

                Section {
                    Toggle("Keep i2pd alive in background", isOn: $keepAlive)
                        .onChange(of: keepAlive) { value in
                            I2pdCore.applyKeepAlive()
                        }
                } header: {
                    Text("General")
                } footer: {
                    Text("Without keep-alive, iOS suspends the app and the proxy stops. Keep-alive plays silent audio so i2pd stays up in the background (battery impact).")
                }

                Section {
                    NavigationLink(isActive: $showConsole) {
                        WebConsoleView(url: consoleURL)
                    } label: {
                        Label("Open web console", systemImage: "globe")
                    }
                } header: {
                    Text("Web console")
                } footer: {
                    Text("Opens the i2pd web console through the backloop HTTPS server, so it is reachable in this browser or Safari with a trusted certificate. Start the router first.")
                }
            }
            .modifier(HiddenScrollBackground())
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle("Proxy")
            .onAppear {
                sslExpiry = I2pdCore.sslExpiryString
            }
            .alert("ios2pd", isPresented: alertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func refreshSsl() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            var message = ""
            do {
                try I2pdCore.refreshSsl()
                ok = true
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                busy = false
                sslExpiry = I2pdCore.sslExpiryString
                alertMessage = ok
                    ? "SSL certificate updated from backloop.dev."
                    : "Update failed: \(message.isEmpty ? "unknown error" : message)"
            }
        }
    }

    private func installProfile() {
        guard !busy else { return }
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespaces)
        guard !trimmedSSID.isEmpty else {
            alertMessage = "Enter your Wi-Fi SSID first (Proxy > Wi-Fi network)."
            return
        }
        ssid = trimmedSSID
        if I2pdCore.hasSslCert {
            doInstall()
        } else {
            busy = true
            DispatchQueue.global(qos: .userInitiated).async {
                var ready = false
                do {
                    try I2pdCore.refreshSsl()
                    ready = true
                } catch {
                    // message is surfaced below
                }
                DispatchQueue.main.async {
                    busy = false
                    if ready {
                        doInstall()
                    } else {
                        alertMessage = "SSL setup failed - check your connection."
                    }
                }
            }
        }
    }

    private func doInstall() {
        I2pdCore.startSslServer()
        let h = host.trimmingCharacters(in: .whitespaces)
        let url = URL(string: "https://\(h.isEmpty ? "ios2pd.backloop.dev" : h):\(port)/install.mobileconfig")
        guard let url = url else {
            alertMessage = "Could not build the profile URL."
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                alertMessage = "Could not open Safari. Make sure Wi-Fi is available."
            }
        }
    }
}

/// Direct-mode browser for the web console: loads the backloop HTTPS URL
/// through a plain WKWebView (no i2p scheme handler).
struct WebConsoleView: View {
    let url: URL

    var body: some View {
        DirectWebView(url: url)
            .ignoresSafeArea(edges: .bottom)
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle("Web console")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                I2pdCore.startSslServer()
            }
    }
}

struct DirectWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}
    }
}
