//  HomeView.swift — connect/disconnect the I2P tunnel, plus a small readout of
//  what the router is doing.

import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var vpn: VpnController

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.61.0"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    connection
                    router
                    hint
                }
                .padding(Theme.pagePadding)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("ios2pd")
            .navigationBarTitleDisplayMode(.large)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            vpn.refresh()
        }
        .alert("Tunnel error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vpn.errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { vpn.errorMessage != nil },
            set: { if !$0 { vpn.errorMessage = nil } }
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("ios2pd").font(.title3.weight(.semibold))
                Text("i2pd \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                Text(vpn.statusText)
                    .font(.title2.weight(.semibold))
                Spacer()
                if vpn.isBusy { ProgressView() }
            }
            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ActionButton(
                title: vpn.isOn ? "Disconnect" : "Connect",
                systemImage: vpn.isOn ? "stop.fill" : "bolt.fill",
                tint: vpn.isOn ? Theme.destructive : Theme.accent,
                action: vpn.toggle
            )
        }
        .padding(18)
        .liquidGlass()
    }

    private var dotColor: Color {
        switch vpn.status {
        case .connected: return Theme.affirmative
        case .connecting, .reasserting, .disconnecting: return Theme.caution
        default: return .secondary
        }
    }

    private var detailText: String {
        switch vpn.status {
        case .connected:
            return vpn.stats.inbound > 0
                ? "Tunnels are up. .i2p addresses now resolve on this device."
                : "Building tunnels — this takes a minute on a cold start."
        case .connecting: return "Starting the router and reseeding."
        case .disconnecting: return "Shutting the router down."
        case .reasserting: return "Reconnecting after a network change."
        case .invalid: return "Tap Connect to install the tunnel profile."
        default: return "The router is stopped."
        }
    }

    private var router: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Router", detail: vpn.stats.status)
            VStack(spacing: 0) {
                row("Uptime", uptimeText, "clock")
                Divider().padding(.leading, 36)
                row("Tunnels", "\(vpn.stats.inbound) in · \(vpn.stats.outbound) out", "arrow.up.arrow.down")
                Divider().padding(.leading, 36)
                row("Known routers", "\(vpn.stats.routers)", "point.3.connected.trianglepath.dotted")
                Divider().padding(.leading, 36)
                row("HTTP proxy", "127.0.0.1:4444", "network")
            }
            .padding(.horizontal, 18)
            .liquidGlass()
        }
    }

    private var uptimeText: String {
        let seconds = vpn.stats.uptime
        guard seconds > 0 else { return "—" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    private func row(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
        .padding(.vertical, 13)
    }

    private var hint: some View {
        Label(
            "While connected, .i2p addresses open in Safari and any other app. Everything else keeps using your normal connection.",
            systemImage: "info.circle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
