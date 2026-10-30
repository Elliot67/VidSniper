import AppKit
import SwiftUI

/// Palette inspirée d'Obsidian, qui suit le thème clair/sombre du système.
enum Theme {
    static let backgroundPrimary = dynamic(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let backgroundSecondary = dynamic(light: 0xF6F6F6, dark: 0x262626)
    static let border = dynamic(light: 0xE0E0E0, dark: 0x363636)
    static let textNormal = dynamic(light: 0x222222, dark: 0xDADADA)
    static let textMuted = dynamic(light: 0x5C5C5C, dark: 0x999999)
    static let accent = dynamic(light: 0x8A5CF5, dark: 0x8A5CF5)
    static let accentHover = dynamic(light: 0x7A4CE5, dark: 0x9D76F7)
    static let success = dynamic(light: 0x08B94E, dark: 0x44CF6E)
    static let error = dynamic(light: 0xE93147, dark: 0xFB464C)

    static let cornerRadius: CGFloat = 6
    static let spacing: CGFloat = 12

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Bouton principal plein, couleur d'accent.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(configuration.isPressed ? Theme.accentHover : Theme.accent)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Bouton rond avec une icône seule.
struct IconButtonStyle: ButtonStyle {
    var tint: Color = Theme.textNormal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(configuration.isPressed ? Theme.border : Theme.backgroundSecondary)
            )
            .contentShape(Circle())
    }
}

/// Bouton secondaire, fond discret et bordure fine.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Theme.textNormal)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(configuration.isPressed ? Theme.border : Theme.backgroundPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
