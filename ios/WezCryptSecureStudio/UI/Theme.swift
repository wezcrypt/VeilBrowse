import SwiftUI
import UIKit

/// Premium dark-first palette: black, charcoal and a calm blue accent, with
/// light-mode counterparts.
enum Theme {
    static let accent = Color("AccentColor")

    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1) : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    })

    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1) : UIColor.white
    })

    static let elevated = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 1) : UIColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1)
    })

    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.08)
    })

    static let placeholder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1) : UIColor(red: 0.88, green: 0.88, blue: 0.90, alpha: 1)
    })

    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    static let cornerRadius: CGFloat = 18
    static let smallRadius: CGFloat = 12

    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.20, green: 0.42, blue: 0.95), Color(red: 0.36, green: 0.58, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button(String(localized: "Retry"), action: retry)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func cardBackground() -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
