//  Theme.swift — shared look: Liquid Glass on iOS 26, system material below.

import SwiftUI
import UIKit

enum Theme {
    static let accent = Color.indigo
    static let affirmative = Color(uiColor: .systemGreen)
    static let caution = Color(uiColor: .systemOrange)
    static let destructive = Color(uiColor: .systemRed)

    static let pagePadding: CGFloat = 20
    static let cardRadius: CGFloat = 24
}

extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    @ViewBuilder
    func glassAction(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct ActionButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    var isBusy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .glassAction(prominent: true)
        .tint(tint)
        .controlSize(.large)
        .disabled(disabled || isBusy)
    }
}
