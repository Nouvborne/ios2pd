//  VpnController.swift — owns the ios2pd tunnel configuration: status,
//  connect/disconnect, and the log and router readout it polls from the
//  extension.
//
//  The i2pd daemon lives in the tunnel extension. Everything shown in the UI
//  comes back over sendProviderMessage — deliberately not through a shared app
//  group, which a sideloading profile will not have registered.

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
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var stats = RouterStats()
    @Published private(set) var log = ""
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?

    /// The extension's real bundle id. Sideloaders routinely rewrite bundle
    /// ids, and naming one that no longer exists makes iOS fail the tunnel with
    /// a bare "internal error", so read it back off the bundle on disk.
    static var providerBundleID: String {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let entries = try? FileManager.default.contentsOfDirectory(
               at: plugins, includingPropertiesForKeys: nil),
           let appex = entries.first(where: { $0.pathExtension == "appex" }),
           let identifier = Bundle(url: appex)?.bundleIdentifier {
            return identifier
        }
        return (Bundle.main.bundleIdentifier ?? "uk.nouvborne.ios2pd") + ".tunnel"
    }

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

    /// Pulls the log tail and router counters from the extension.
    func refresh() {
        guard status == .connected,
              let session = manager?.connection as? NETunnelProviderSession
        else {
            if stats.uptime != 0 { stats = RouterStats() }
            return
        }
        try? session.sendProviderMessage(Data("stats".utf8)) { [weak self] reply in
            guard let reply,
                  let values = (try? JSONSerialization.jsonObject(with: reply))
                    as? [String: Any]
            else { return }
            DispatchQueue.main.async {
                self?.stats = RouterStats(
                    uptime: values["uptime"] as? Int ?? 0,
                    inbound: values["inbound"] as? Int ?? 0,
                    outbound: values["outbound"] as? Int ?? 0,
                    routers: values["routers"] as? Int ?? 0,
                    status: values["status"] as? String ?? "—"
                )
                self?.log = values["log"] as? String ?? ""
            }
        }
    }
}
