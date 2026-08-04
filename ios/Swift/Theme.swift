//  Theme.swift — Liquid Glass helpers for the ios2pd SwiftUI UI.
//
//  On iOS 26 the native glassEffect / glass button styles are used; on older
//  iOS (deployment target is iOS 15) we recreate the glass look with the
//  system ultraThin material, a hairline border and rounded corners.

import SwiftUI

enum GlassTheme {
    /// Subtle dark gradient that the glass surfaces blur, so the Liquid Glass
    /// treatment is actually visible.
    static let background = LinearGradient(
        colors: [
            Color(red: 0.12, green: 0.16, blue: 0.32),
            Color(red: 0.30, green: 0.16, blue: 0.42),
            Color(red: 0.04, green: 0.06, blue: 0.12),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Wraps content in a glass card.
    @ViewBuilder
    static func card<Content: View>(
        cornerRadius: CGFloat = 24,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .background {
                if #available(iOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(.white.opacity(0.22), lineWidth: 0.8)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Fallback pressable glass look for iOS < 26.
struct FallbackGlassButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                prominent ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(prominent ? 0.0 : 0.28), lineWidth: 0.8)
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3), value: configuration.isPressed)
    }
}

extension View {
    /// Applies the Liquid Glass prominent button style (native on iOS 26,
    /// material fallback below).
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(FallbackGlassButtonStyle(prominent: true))
        }
    }

    /// Applies the Liquid Glass plain button style (native on iOS 26,
    /// material fallback below).
    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(FallbackGlassButtonStyle())
        }
    }
}

/// Hides the opaque Form/List background so the gradient shows through.
/// `.scrollContentBackground(.hidden)` is iOS 16+; older iOS keeps the
/// system background.
struct HiddenScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

/// Rounded "pill" that hosts the address bar in the browser.
struct GlassPill: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background {
                if #available(iOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(.white.opacity(0.22), lineWidth: 0.8)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
