//  Ios2pdApp.swift — SwiftUI entry point. Two tabs: Home and Logs.

import SwiftUI

@main
struct Ios2pdApp: App {
    @StateObject private var vpn = VpnController()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(vpn)
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "shield.lefthalf.filled") }
            LogsView()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
        }
    }
}
