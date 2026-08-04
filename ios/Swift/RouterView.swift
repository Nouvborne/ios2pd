//  RouterView.swift — start/stop the i2pd daemon, VPN status, live log.

import SwiftUI

struct RouterView: View {
    @State private var running = I2pdCore.routerRunning
    @State private var starting = false
    @State private var detail = "i2pd is not running"
    @State private var log = I2pdCore.routerLog
    @State private var vpn = I2pdCore.vpnStatus

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    vpnLabel
                    logCard
                }
                .padding(16)
            }
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle("Router")
            .onReceive(
                Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            ) { _ in
                refresh()
            }
        }
    }

    private var statusText: String {
        if running { return "Running" }
        return starting ? "Starting…" : "Stopped"
    }

    private var statusCard: some View {
        GlassTheme.card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(statusText)
                        .font(.title2.bold())
                    Spacer()
                    Circle()
                        .fill(running ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(action: toggle) {
                    Text(running ? "Stop Router" : "Start Router")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassProminentButton()
                .tint(running ? .red : .blue)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var vpnLabel: some View {
        Text("VPN: \(vpn)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: Capsule())
    }

    private var logCard: some View {
        GlassTheme.card(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Log")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("log-end")
                            .padding(12)
                    }
                    .frame(height: 220)
                    .onChange(of: log) { _ in
                        withAnimation(.none) {
                            proxy.scrollTo("log-end", anchor: .bottom)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggle() {
        if running {
            I2pdCore.stopRouter()
            running = false
            detail = "i2pd is not running"
        } else {
            starting = true
            detail = "Building tunnels"
            let ok = I2pdCore.startRouter()
            starting = false
            running = I2pdCore.routerRunning
            if ok && running {
                detail = String(format: "%d tunnels configured", I2pdCore.tunnels.count)
            } else {
                detail = "Failed to start - see log"
            }
        }
    }

    private func refresh() {
        running = I2pdCore.routerRunning
        let newLog = I2pdCore.routerLog
        if newLog != log { log = newLog }
        vpn = I2pdCore.vpnStatus
    }
}
