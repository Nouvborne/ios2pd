//  I2pdSettingsView.swift — daemon settings (HTTP/SOCKS/SAM proxies, log
//  level, advanced i2pd.conf editor).

import SwiftUI

struct I2pdSettingsView: View {
    @AppStorage("i2pd_http_enabled") private var httpEnabled = true
    @AppStorage("i2pd_http_port") private var httpPort = 4444
    @AppStorage("i2pd_socks_enabled") private var socksEnabled = true
    @AppStorage("i2pd_socks_port") private var socksPort = 4447
    @AppStorage("i2pd_sam_enabled") private var samEnabled = true
    @AppStorage("i2pd_sam_port") private var samPort = 7656
    @AppStorage("i2pd_loglevel") private var logLevel = "info"

    var body: some View {
        NavigationView {
            Form {
                proxySection(
                    header: "HTTP proxy (browsers)",
                    footer: "Used by the Wi-Fi proxy profile and by browsers on this device.",
                    enabled: $httpEnabled,
                    port: $httpPort
                )
                proxySection(
                    header: "SOCKS5 proxy",
                    footer: "Used by the optional VPN extension to tunnel *.i2p flows.",
                    enabled: $socksEnabled,
                    port: $socksPort
                )
                proxySection(
                    header: "SAM",
                    footer: "SAM application bridge (advanced).",
                    enabled: $samEnabled,
                    port: $samPort
                )
                Section {
                    Picker("Level", selection: $logLevel) {
                        ForEach(["info", "debug", "warn", "error"], id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                    NavigationLink("Advanced config") {
                        CustomConfView()
                    }
                } header: {
                    Text("Logging & advanced")
                } footer: {
                    Text("Changes apply the next time you start the router.")
                }
            }
            .modifier(HiddenScrollBackground())
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle("i2pd")
        }
    }

    @ViewBuilder
    private func proxySection(
        header: String,
        footer: String,
        enabled: Binding<Bool>,
        port: Binding<Int>
    ) -> some View {
        Section {
            Toggle("Enabled", isOn: enabled)
            HStack {
                Text("Port")
                Spacer()
                TextField("Port", value: port, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }
}

struct CustomConfView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        ScrollView {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 400)
                .modifier(HiddenScrollBackground())
                .padding()
        }
        .background(GlassTheme.background.ignoresSafeArea())
        .navigationTitle("Advanced config")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    I2pdCore.writeCustomConfig(text)
                    dismiss()
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = I2pdCore.customConfigText
        }
    }
}
