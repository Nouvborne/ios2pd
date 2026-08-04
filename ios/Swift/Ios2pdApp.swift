//  Ios2pdApp.swift — SwiftUI entry point for ios2pd.
//  Five tabs: Router, Browser, Tunnels, i2pd, Proxy.

import SwiftUI
import UIKit

@main
struct Ios2pdApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            RouterView()
                .tabItem { Label("Router", systemImage: "network") }
            BrowserView()
                .tabItem { Label("Browser", systemImage: "safari") }
            TunnelsView()
                .tabItem { Label("Tunnels", systemImage: "arrow.up.arrow.down") }
            I2pdSettingsView()
                .tabItem { Label("i2pd", systemImage: "switch.2") }
            ProxyView()
                .tabItem { Label("Proxy", systemImage: "globe") }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        I2pdCore.prepare()
        I2pdCore.applyKeepAlive()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        I2pdCore.stopRouter()
        I2pdCore.stopSslServer()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        I2pdCore.applyKeepAlive()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        I2pdCore.applyKeepAlive()
    }
}
