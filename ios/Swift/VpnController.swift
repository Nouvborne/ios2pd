//  VpnController.swift — owns the ios2pd tunnel configuration: status,
//  connect/disconnect, and the router readout the extension drops into the
//  shared app-group container.
//
//  The i2pd daemon itself lives in the tunnel extension, not here, so the app
//  never talks to it directly — it reads two files the extension writes.

import Foundation
import NetworkExtension

struct RouterStats {
    var uptime = 0
    var inbound = 0
    var outbound = 0
    var routers = 0
    var status = "—"
}

final class VpnController: ObservableObject {
    static let appGroup = "group.uk.nouvborne.ios2pd"
    private static let providerBundleID = "uk.nouvborne.ios2pd.tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var stats = RouterStats()
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?

    init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncStatus()
        }
        reload()
    }

    var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .reasserting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .invalid: return "Not configured"
        @unknown default: return "Unknown"
        }
    }

    var isBusy: Bool {
        status == .connecting || status == .disconnecting || status == .reasserting
    }

    var isOn: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    func reload() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            DispatchQueue.main.async {
                self?.manager = managers?.first
                self?.syncStatus()
            }
        }
    }

    func toggle() {
        if isOn {
            manager?.connection.stopVPNTunnel()
        } else {
            start()
        }
    }

    private func syncStatus() {
        let previous = status
        status = manager?.connection.status ?? .invalid
        let wasLive = previous == .connecting || previous == .reasserting || previous == .connected
        if status == .disconnected && wasLive { captureDisconnectError() }
    }

    /// Why the tunnel stopped. Without this a failing extension just drops back
    /// to Disconnected with nothing shown — the error never reaches the app
    /// through the start path.
    private func captureDisconnectError() {
        guard let connection = manager?.connection, connection.status != .invalid else { return }
        connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.errorMessage = "Tunnel stopped: \(error.localizedDescription)"
            }
        }
    }

    /// False when the app group entitlement did not survive signing, which
    /// makes the log and stats files unreadable even though the VPN may run.
    static var sharedContainerAvailable: Bool { sharedURL != nil }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
    }

    private func start() {
        errorMessage = nil
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error { self.fail(error); return }

            let manager = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleID
            proto.serverAddress = "I2P"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "ios2pd"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError { self.fail(saveError); return }
                // Reloading after a save is required: starting straight off the
                // just-saved object fails with a stale-configuration error.
                manager.loadFromPreferences { loadError in
                    if let loadError { self.fail(loadError); return }
                    DispatchQueue.main.async {
                        self.manager = manager
                        do {
                            try manager.connection.startVPNTunnel()
                        } catch {
                            self.errorMessage = error.localizedDescription
                        }
                        self.syncStatus()
                    }
                }
            }
        }
    }

    func refreshStats() {
        // The extension stops updating status.plist the moment it goes away —
        // including when it is killed — so don't keep showing its last numbers.
        guard status == .connected else {
            stats = RouterStats()
            return
        }
        guard let url = Self.sharedURL?.appendingPathComponent("status.plist"),
              let values = NSDictionary(contentsOf: url) as? [String: Any]
        else { return }
        stats = RouterStats(
            uptime: values["uptime"] as? Int ?? 0,
            inbound: values["inbound"] as? Int ?? 0,
            outbound: values["outbound"] as? Int ?? 0,
            routers: values["routers"] as? Int ?? 0,
            status: values["status"] as? String ?? "—"
        )
    }

    static var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Tail of the daemon log the extension writes. Reads only the last
    /// `maxBytes` so a long session doesn't pull megabytes into memory.
    static func logTail(maxBytes: UInt64 = 64 * 1024) -> String {
        guard let url = sharedURL?.appendingPathComponent("i2pd.log"),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > maxBytes ? end - maxBytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
