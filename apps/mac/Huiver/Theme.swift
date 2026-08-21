import SwiftUI

/// The web app's design tokens, exactly as `apps/ios/Huiver/Theme.swift` has
/// them — the Mac and the phone share a palette the way they share HuiverKit,
/// but each app compiles its own copy because the tokens live with the views,
/// not with the engine.
enum Palette {
    struct Colors {
        let background: Color
        let foreground: Color
        let card: Color
        let primary: Color
        let primaryForeground: Color
        let muted: Color
        let mutedForeground: Color
        let destructive: Color
        let border: Color
    }

    static let light = Colors(
        background: hex(0xfd_fc_f9),
        foreground: hex(0x0a_0a_0a),
        card: hex(0xff_ff_ff),
        primary: hex(0xb9_4a_00),
        primaryForeground: hex(0xfd_fa_f3),
        muted: hex(0xf5_f5_f5),
        mutedForeground: hex(0x73_73_73),
        destructive: hex(0xe7_00_0b),
        border: hex(0xe5_e5_e5)
    )

    static let dark = Colors(
        background: hex(0x0f_0d_0b),
        foreground: hex(0xf6_f5_f2),
        card: hex(0x19_17_14),
        primary: hex(0xf5_91_45),
        primaryForeground: hex(0x1a_10_0a),
        muted: hex(0x26_26_26),
        mutedForeground: hex(0xa1_a1_a1),
        destructive: hex(0xff_64_67),
        border: hex(0x2a_27_24)
    )

    static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// `--radius: 0.625rem` and its Tailwind-derived steps.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 14
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}

/// Resolves the palette against the current appearance.
///
/// A plain environment lookup rather than a token system: the app is small
/// enough that `theme.primary` at the point of use is clearer than a wrapper
/// view per colour.
struct Theme {
    let colors: Palette.Colors

    init(_ scheme: ColorScheme) {
        colors = scheme == .dark ? Palette.dark : Palette.light
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(.light)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Reads the appearance where it can actually be seen. `colorScheme` in the
/// `App` struct is resolved once, outside any window, so a theme built there
/// is light for good — this modifier lives in the view tree, where the value
/// tracks the window and updates when the system switches.
private struct HuiverThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = Theme(scheme)
        content
            .environment(\.theme, theme)
            .tint(theme.colors.primary)
    }
}

extension View {
    /// Installs the palette for the current appearance, and tints the standard
    /// controls with it so buttons and progress bars match without every call
    /// site saying so.
    func huiverTheme() -> some View {
        modifier(HuiverThemeModifier())
    }
}

extension Font {
    // The type ramp from tokens.ts, mapped onto Dynamic Type so the app still
    // respects the reader's chosen size.
    static let huiverTitle = Font.system(.title2, design: .default, weight: .semibold)
    static let huiverHeading = Font.system(.headline, weight: .semibold)
    static let huiverBody = Font.system(.subheadline)
    static let huiverLabel = Font.system(.footnote, weight: .medium)
    static let huiverCaption = Font.system(.caption)
}
