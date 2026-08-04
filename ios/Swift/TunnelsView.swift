//  TunnelsView.swift — client/server tunnel list + editor.

import SwiftUI

struct TunnelModel {
    var name: String = ""
    var type: String = "client"
    var port: String = "0"
    var address: String = "127.0.0.1"
    var destination: String = ""
    var destinationPort: String = ""
    var host: String = "127.0.0.1"
    var inport: String = ""
    var keys: String = ""

    init() {}

    init(dict: [AnyHashable: Any]) {
        name = dict["name"] as? String ?? ""
        type = dict["type"] as? String ?? "client"
        port = String(describing: dict["port"] ?? "0")
        address = dict["address"] as? String ?? "127.0.0.1"
        destination = dict["destination"] as? String ?? ""
        destinationPort = dict["destinationport"] as? String ?? ""
        host = dict["host"] as? String ?? "127.0.0.1"
        inport = dict["inport"] as? String ?? ""
        keys = dict["keys"] as? String ?? ""
    }

    var dictionary: [AnyHashable: Any] {
        var d: [AnyHashable: Any] = ["name": name, "type": type, "port": port]
        if type == "client" || type == "socks" { d["address"] = address }
        if type == "client" {
            d["destination"] = destination
            d["destinationport"] = destinationPort
        }
        if type == "server" || type == "http" {
            d["host"] = host
            d["inport"] = inport
        }
        if !keys.isEmpty { d["keys"] = keys }
        return d
    }
}

struct EditorPayload: Identifiable {
    let id = UUID()
    let model: TunnelModel
    let index: Int?
}

struct TunnelsView: View {
    @State private var tunnels: [[AnyHashable: Any]] = I2pdCore.tunnels()
    @State private var editor: EditorPayload?
    @State private var showTypePicker = false

    private var clientTunnels: [(dict: [AnyHashable: Any], index: Int)] {
        tunnels.enumerated().compactMap { idx, t in
            let type = t["type"] as? String ?? "client"
            return (type == "client" || type == "socks") ? (t, idx) : nil
        }
    }

    private var serverTunnels: [(dict: [AnyHashable: Any], index: Int)] {
        tunnels.enumerated().compactMap { idx, t in
            let type = t["type"] as? String ?? "client"
            return (type == "server" || type == "http") ? (t, idx) : nil
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(clientTunnels, id: \.index) { item in
                        Button {
                            editor = EditorPayload(model: TunnelModel(dict: item.dict), index: item.index)
                        } label: {
                            tunnelRow(item.dict)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in delete(from: clientTunnels, offsets: offsets) }
                } header: {
                    Text("Client tunnels (outgoing)")
                } footer: {
                    Text("Client tunnels expose a local port that forwards to an I2P service - e.g. mail.i2p (Postman), IRC, etc.")
                }

                Section {
                    ForEach(serverTunnels, id: \.index) { item in
                        Button {
                            editor = EditorPayload(model: TunnelModel(dict: item.dict), index: item.index)
                        } label: {
                            tunnelRow(item.dict)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in delete(from: serverTunnels, offsets: offsets) }
                } header: {
                    Text("Server tunnels (incoming)")
                } footer: {
                    Text("Server tunnels publish a service running on this device to I2P. Changes apply the next time you start the router.")
                }
            }
            .modifier(HiddenScrollBackground())
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle("Tunnels")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showTypePicker = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .confirmationDialog("Add tunnel", isPresented: $showTypePicker, titleVisibility: .visible) {
                Button("Client tunnel (to an I2P service)") { addNew("client", "new-client") }
                Button("Server tunnel (host a service)") { addNew("server", "new-server") }
                Button("HTTP tunnel") { addNew("http", "new-http") }
                Button("Postman e-mail preset (mail.i2p)") { addPostmanPreset() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $editor) { payload in
                TunnelEditorView(model: payload.model, index: payload.index) { saved in
                    editor = nil
                    reload()
                }
            }
        }
    }

    private func tunnelRow(_ t: [AnyHashable: Any]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t["name"] as? String ?? "?")
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle(for: t))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for t: [AnyHashable: Any]) -> String {
        let type = t["type"] as? String ?? "client"
        let address = t["address"] as? String ?? "127.0.0.1"
        let port = String(describing: t["port"] ?? "0")
        switch type {
        case "client":
            return "client  \(address):\(port) -> \(t["destination"] as? String ?? "?")"
        case "socks":
            return "socks  \(address):\(port)"
        case "http":
            return "http  <- \(t["host"] as? String ?? "127.0.0.1"):\(port)"
        default:
            return "server  <- \(t["host"] as? String ?? "127.0.0.1"):\(port)"
        }
    }

    private func delete(from items: [(dict: [AnyHashable: Any], index: Int)], offsets: IndexSet) {
        var list = I2pdCore.tunnels()
        for offset in offsets {
            let index = items[offset].index
            if index >= 0 && index < list.count {
                list.remove(at: index)
            }
        }
        I2pdCore.saveTunnels(list)
        reload()
    }

    private func addNew(_ type: String, _ name: String) {
        var model = TunnelModel()
        model.type = type
        model.name = name
        editor = EditorPayload(model: model, index: nil)
    }

    private func addPostmanPreset() {
        var list = I2pdCore.tunnels()
        list.append(TunnelModel(dict: [
            "name": "mail-smtp", "type": "client",
            "address": "127.0.0.1", "port": "515",
            "destination": "smtp.postman.i2p", "keys": "mail.dat",
        ]).dictionary)
        list.append(TunnelModel(dict: [
            "name": "mail-pop3", "type": "client",
            "address": "127.0.0.1", "port": "616",
            "destination": "pop.postman.i2p", "keys": "mail.dat",
        ]).dictionary)
        I2pdCore.saveTunnels(list)
        reload()
    }

    private func reload() {
        tunnels = I2pdCore.tunnels()
    }
}

struct TunnelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: TunnelModel
    private let index: Int?
    private let onSave: (Bool) -> Void

    init(model: TunnelModel, index: Int?, onSave: @escaping (Bool) -> Void) {
        _model = State(initialValue: model)
        self.index = index
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Name") {
                    TextField("Tunnel name", text: $model.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Type") {
                    Picker("Type", selection: $model.type) {
                        Text("client").tag("client")
                        Text("server").tag("server")
                        Text("http").tag("http")
                        Text("socks").tag("socks")
                    }
                    .pickerStyle(.menu)
                }
                Section("Local port") {
                    TextField("Port", text: $model.port)
                        .keyboardType(.numberPad)
                }
                if model.type == "client" || model.type == "socks" {
                    Section("Bind address") {
                        TextField("127.0.0.1", text: $model.address)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                    }
                }
                if model.type == "client" {
                    Section {
                        TextField("Destination (.i2p)", text: $model.destination)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Destination port", text: $model.destinationPort)
                            .keyboardType(.numberPad)
                    } header: {
                        Text("Destination")
                    }
                }
                if model.type == "server" || model.type == "http" {
                    Section("Server") {
                        TextField("Host", text: $model.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("I2P inport", text: $model.inport)
                            .keyboardType(.numberPad)
                    }
                }
                Section("Keys file") {
                    TextField("e.g. mail.dat", text: $model.keys)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .modifier(HiddenScrollBackground())
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle(index == nil ? "Add tunnel" : "Edit tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let name = model.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return
        }
        let port = Int(model.port.trimmingCharacters(in: .whitespaces)) ?? 0
        guard port >= 1 && port <= 65535 else {
            return
        }
        model.name = name
        model.port = String(port)
        if model.type == "client",
           model.destination.trimmingCharacters(in: .whitespaces).isEmpty {
            return
        }
        var list = I2pdCore.tunnels()
        if let index = index, index >= 0 && index < list.count {
            list[index] = model.dictionary
        } else {
            list.append(model.dictionary)
        }
        I2pdCore.saveTunnels(list)
        onSave(true)
        dismiss()
    }
}
