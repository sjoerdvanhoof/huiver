import SwiftUI

/// The Narcisse "Gilded Pool" tokens: still water and gold. Light mode is a
/// warm ivory page with deep antique gold as the accent; dark mode is
/// water-green ink with a brighter gold. The gold `primary` is the point of
/// the palette: play controls and progress read as the app's mirror-and-water
/// theme rather than a generic blue.
///
/// All foreground/background pairs were checked against WCAG AA — the light
/// primary is deliberately darker than the brand gold so labels on ivory pass.
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
        background: hex(0xfa_f7_ee),
        foreground: hex(0x14_20_1b),
        card: hex(0xff_fd_f6),
        primary: hex(0x8a_61_10),
        primaryForeground: hex(0xff_fb_f0),
        muted: hex(0xef_eb_dd),
        mutedForeground: hex(0x5c_6b_60),
        destructive: hex(0xc0_36_2c),
        border: hex(0xe2_dc_ca)
    )

    static let dark = Colors(
        background: hex(0x0b_16_13),
        foreground: hex(0xf4_f1_e6),
        card: hex(0x14_20_19),
        primary: hex(0xe3_b3_4c),
        primaryForeground: hex(0x1c_15_04),
        muted: hex(0x1c_2a_24),
        mutedForeground: hex(0xa3_b3_a6),
        destructive: hex(0xff_6b_62),
        border: hex(0x24_35_2c)
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
/// `App` struct is resolved once, outside any window, so a theme built there is
/// light for good — this modifier lives in the view tree, where the value
/// tracks the window and updates when the system switches.
///
/// Taking the scheme as an argument is what went wrong before: the app passed
/// the `App`'s value (always light) and `LibraryView` passed its own (correctly
/// dark), which put two palettes in one window — a light background with
/// light-on-light titles drawn over it. There is no argument to get wrong now.
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
    // respects the reader's chosen size — which the React Native version, with
    // its fixed point sizes, does not.
    static let huiverTitle = Font.system(.title2, design: .default, weight: .semibold)
    static let huiverHeading = Font.system(.headline, weight: .semibold)
    static let huiverBody = Font.system(.subheadline)
    static let huiverLabel = Font.system(.footnote, weight: .medium)
    static let huiverCaption = Font.system(.caption)
}
