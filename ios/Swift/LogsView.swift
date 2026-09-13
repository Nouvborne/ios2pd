//  LogsView.swift — live tail of the i2pd log, polled from the tunnel
//  extension while it is connected.

import SwiftUI
import UIKit
import NetworkExtension

struct LogsView: View {
    @EnvironmentObject private var vpn: VpnController
    @State private var follow = true

    private var lines: [String] {
        vpn.log
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(300)
            .map(String.init)
    }

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty { empty } else { content(lines) }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = vpn.log
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(vpn.log.isEmpty)
                    .accessibilityLabel("Copy log")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        follow.toggle()
                    } label: {
                        Image(systemName: follow ? "arrow.down.to.line.compact" : "pause")
                    }
                    .accessibilityLabel(follow ? "Following new output" : "Scrolling paused")
                }
            }
        }
    }

    private func content(_ lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(Theme.pagePadding)
            }
            .scrollIndicators(.hidden)
            .onChange(of: lines.count) { count in
                guard follow, count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No output yet").font(.headline)
            Text(vpn.status == .connected
                 ? "The router is starting up."
                 : "Connect on the Home tab to start the router.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
