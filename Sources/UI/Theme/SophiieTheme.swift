import AppKit
import SwiftUI

/// Sophiie design tokens for the native app, translated from the whispur.app
/// site (`public/styles.css`, which mirrors the Sophiie www `@theme` block).
///
/// Colours are appearance-aware: every semantic colour resolves to a light
/// and a dark value at draw time, so views follow the system appearance
/// without branching on `colorScheme`. Light values are the site tokens;
/// dark values keep the midnight and sky identity with text at 4.5:1 or
/// better against the dark surfaces they sit on.
enum SophiieTheme {

    // MARK: - Colour

    enum Palette {
        // Brand constants (appearance independent).
        static let midnight = Color(hex: 0x140934)
        static let navy = Color(hex: 0x151587)
        static let sky = Color(hex: 0x69C7FB)

        // Text.
        /// Primary text. Light: midnight #140934. Dark: #F3F2F8.
        static let ink = Color(light: 0x140934, dark: 0xF3F2F8)
        /// Secondary text. Light: #323745. Dark: #C8C5D8.
        static let inkSecondary = Color(light: 0x323745, dark: 0xC8C5D8)
        /// Muted text and captions. Light: #65696F. Dark: #9C98B0.
        static let muted = Color(light: 0x65696F, dark: 0x9C98B0)
        /// Links and inline interactive text. Light: #2A6AA8. Dark: #8FD3FC.
        static let interactive = Color(light: 0x2A6AA8, dark: 0x8FD3FC)

        // Surfaces.
        /// Cards and raised content. Light: white. Dark: #1B1433.
        static let surface = Color(light: 0xFFFFFF, dark: 0x1B1433)
        /// Window canvas. Light: warm #F8F8F6. Dark: deep midnight #120C24.
        /// Every window (menu bar, settings, onboarding) paints this opaque
        /// stage so cards sit on one surface family instead of the system
        /// material.
        static let surfaceWarm = Color(light: 0xF8F8F6, dark: 0x120C24)
        /// Sidebars and recessed areas. Light: #F2F1EE. Dark: #0D0819.
        static let surfaceStage = Color(light: 0xF2F1EE, dark: 0x0D0819)
        /// Quiet fills for chips and wells on top of any surface.
        static let surfaceSubtle = Color(light: 0x140934, lightAlpha: 0.045, dark: 0xFFFFFF, darkAlpha: 0.07)
        /// Selected rows. Light: #E8F4FF. Dark: #22284A.
        static let surfaceSelected = Color(light: 0xE8F4FF, dark: 0x22284A)

        // Strokes.
        /// Default card border. Light: #EDEFF3. Dark: #2A2345.
        static let border = Color(light: 0xEDEFF3, dark: 0x2A2345)
        /// Hairline outline used by secondary buttons (rest).
        static let hairline = Color(light: 0x140934, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.14)
        /// Hairline outline (hover).
        static let hairlineStrong = Color(light: 0x140934, lightAlpha: 0.20, dark: 0xFFFFFF, darkAlpha: 0.24)
        /// Secondary button outline. At least 3:1 against both the canvas
        /// and card surfaces so the button boundary stays perceivable.
        /// Light: #85829B. Dark: #6E688C.
        static let controlBorder = Color(light: 0x85829B, dark: 0x6E688C)
        /// Secondary button outline (hover).
        static let controlBorderStrong = Color(light: 0x65627D, dark: 0x8C86AA)
        /// Empty slots in charts and meters: quiet but clearly visible on a
        /// card. Light: #E3E1EA. Dark: #40395E.
        static let track = Color(light: 0xE3E1EA, dark: 0x40395E)

        // Brand roles.
        /// Solid primary fill: midnight in light, sky in dark (midnight on
        /// a dark canvas would disappear).
        static let brand = Color(light: 0x140934, dark: 0x69C7FB)
        /// Label colour on top of `brand`. White on midnight (18.8:1),
        /// midnight on sky (10.0:1).
        static let onBrand = Color(light: 0xFFFFFF, dark: 0x140934)
        /// App-wide control tint (toggles, progress, prominent controls).
        static let accent = brand
        /// Data highlight (sparklines, meters). Sky in dark mode; a deeper
        /// sky in light mode so it holds 3:1 against white and `track`.
        static let highlight = Color(light: 0x1C80BF, dark: 0x69C7FB)

        // Status. Text-safe (at least 5:1) on surface in each mode.
        static let success = Color(light: 0x1B7A4A, dark: 0x5FD39A)
        static let warning = Color(light: 0x9A5B00, dark: 0xF2B35A)
        static let danger = Color(light: 0xC02B45, dark: 0xFF7A8C)

        /// Colours for always-dark floating chrome (recording overlay,
        /// learning toast, share card). These sit on midnight regardless of
        /// the system appearance, like a HUD.
        enum OnDark {
            static let background = Color(hex: 0x140934)
            static let raised = Color.white.opacity(0.12)
            static let ink = Color.white
            static let inkSecondary = Color.white.opacity(0.72)
            static let muted = Color.white.opacity(0.56)
            static let hairline = Color.white.opacity(0.10)
            static let accent = Color(hex: 0x69C7FB)
            static let onAccent = Color(hex: 0x140934)
            static let success = Color(hex: 0x5FD39A)
            static let warning = Color(hex: 0xF2B35A)
            static let danger = Color(hex: 0xFF7A8C)
        }
    }

    // MARK: - Shape and spacing

    enum Radius {
        /// Chips, wells, small inline elements.
        static let small: CGFloat = 6
        /// Buttons and inputs (site buttons are radius 8).
        static let control: CGFloat = 8
        /// Cards and rows.
        static let card: CGFloat = 12
        /// Large panels and grouped sections.
        static let panel: CGFloat = 16
        /// Floating overlays.
        static let overlay: CGFloat = 20
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Type

    /// System type (SF) on the site's scale and weights. Native apps keep
    /// the system face; the Sophiie feel comes from weight and tracking.
    enum Typography {
        static let display = Font.system(size: 28, weight: .semibold).monospacedDigit()
        static let title = Font.title3.weight(.semibold)
        /// Page titles at the top of a window's detail pane.
        static let pageTitle = Font.system(size: 22, weight: .semibold)
        static let heading = Font.headline
        static let body = Font.body
        static let label = Font.subheadline.weight(.medium)
        static let caption = Font.caption
        static let captionStrong = Font.caption.weight(.semibold)
        static let mono = Font.system(.caption, design: .monospaced)
        /// Tracking for titles and display numerals (site headings use
        /// negative tracking).
        static let titleTracking: CGFloat = -0.3
        static let displayTracking: CGFloat = -0.8
        /// Tracking for small uppercase eyebrows.
        static let eyebrowTracking: CGFloat = 1
    }

    // MARK: - Shadow

    enum Shadow {
        /// Midnight-tinted shadows, never pure black.
        static let tint = Color(hex: 0x140934)
    }

    // MARK: - Motion

    /// One easing (`cubic-bezier(0.2, 0, 0, 1)`), short and medium
    /// durations. No springs or bounce.
    enum Motion {
        static let short: Double = 0.2
        static let medium: Double = 0.35

        static func emphasized(_ duration: Double = short) -> Animation {
            .timingCurve(0.2, 0, 0, 1, duration: duration)
        }

        /// The standard animation, or `nil` when Reduce Motion is on.
        static func standard(_ duration: Double = short, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : emphasized(duration)
        }
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(sophiieHex: hex, alpha: alpha))
    }

    /// An appearance-aware colour that resolves against the drawing
    /// appearance, so it follows light and dark mode automatically.
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        let lightColor = NSColor(sophiieHex: light, alpha: lightAlpha)
        let darkColor = NSColor(sophiieHex: dark, alpha: darkAlpha)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

extension NSColor {
    convenience init(sophiieHex hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

// MARK: - Animation helper

/// `withAnimation` using the Sophiie standard curve. Skips the animation
/// when Reduce Motion is on (read from the system, so it works outside a
/// view's environment).
@MainActor
func withSophiieAnimation<Result>(
    _ duration: Double = SophiieTheme.Motion.short,
    _ body: () throws -> Result
) rethrows -> Result {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    return try withAnimation(SophiieTheme.Motion.standard(duration, reduceMotion: reduceMotion), body)
}

extension View {
    /// Applies the Sophiie standard animation for `value`, skipped when
    /// Reduce Motion is on.
    func sophiieAnimation<V: Equatable>(_ duration: Double = SophiieTheme.Motion.short, value: V) -> some View {
        modifier(SophiieAnimationModifier(duration: duration, value: value))
    }

    /// A content card: surface fill, hairline border, card radius.
    func sophiieCard(
        padding: CGFloat = SophiieTheme.Spacing.lg,
        radius: CGFloat = SophiieTheme.Radius.panel,
        fill: Color = SophiieTheme.Palette.surface
    ) -> some View {
        self
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(SophiieTheme.Palette.border, lineWidth: 1)
            )
    }

    /// A text input: surface fill with a 3:1 control outline that thickens
    /// to the brand colour while focused. Pair with `.textFieldStyle(.plain)`.
    func sophiieField(isFocused: Bool) -> some View {
        self
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(SophiieTheme.Palette.surface, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                    .strokeBorder(
                        isFocused ? SophiieTheme.Palette.brand : SophiieTheme.Palette.controlBorder,
                        lineWidth: isFocused ? 2 : 1
                    )
            )
    }

    /// A quiet well: subtle fill, no border.
    func sophiieWell(
        padding: CGFloat = SophiieTheme.Spacing.md,
        radius: CGFloat = SophiieTheme.Radius.card
    ) -> some View {
        self
            .padding(padding)
            .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct SophiieAnimationModifier<V: Equatable>: ViewModifier {
    let duration: Double
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(SophiieTheme.Motion.standard(duration, reduceMotion: reduceMotion), value: value)
    }
}

// MARK: - Buttons

/// Site-style buttons: radius 8, medium label, emphasized easing on hover.
/// `primary` is solid brand (midnight in light, sky in dark); `secondary`
/// is a surface fill with a 3:1 control outline.
struct SophiieButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        /// Primary on always-dark chrome (overlay, toast): sky fill.
        case primaryOnDark
        /// Secondary on always-dark chrome: translucent white.
        case secondaryOnDark
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        SophiieButtonBody(kind: kind, configuration: configuration)
    }
}

private struct SophiieButtonBody: View {
    private typealias Palette = SophiieTheme.Palette
    private typealias OnDark = SophiieTheme.Palette.OnDark

    let kind: SophiieButtonStyle.Kind
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height)
            .background {
                ZStack {
                    shape.fill(background)
                    shape.fill(Color.white.opacity(hoverLift))
                    shape.fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0))
                }
            }
            .overlay(stroke)
            .shadow(color: shadowColor, radius: isHovering ? 6 : 3, y: isHovering ? 3 : 1)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = isEnabled && $0 }
            .animation(SophiieTheme.Motion.standard(reduceMotion: reduceMotion), value: isHovering)
            .animation(SophiieTheme.Motion.standard(reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Palette.onBrand
        case .secondary: return Palette.ink
        case .primaryOnDark: return OnDark.onAccent
        case .secondaryOnDark: return OnDark.ink
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Palette.brand
        case .secondary: return isHovering ? Palette.surfaceSubtle : Palette.surface
        case .primaryOnDark: return OnDark.accent
        case .secondaryOnDark: return isHovering ? Color.white.opacity(0.18) : OnDark.raised
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch kind {
        case .secondary:
            shape.strokeBorder(isHovering ? Palette.controlBorderStrong : Palette.controlBorder, lineWidth: 1)
        default:
            EmptyView()
        }
    }

    /// Primary hover lightens by mixing in white (site: 88% brand, 12% white).
    private var hoverLift: Double {
        guard isHovering, !configuration.isPressed else { return 0 }
        switch kind {
        case .primary: return colorScheme == .dark ? 0.18 : 0.12
        case .primaryOnDark: return 0.18
        default: return 0
        }
    }

    private var shadowColor: Color {
        guard isEnabled, kind == .primary || kind == .secondary, colorScheme == .light else { return .clear }
        return SophiieTheme.Shadow.tint.opacity(isHovering ? 0.10 : 0.06)
    }

    private var height: CGFloat {
        switch controlSize {
        case .mini: return 20
        case .small: return 24
        case .large, .extraLarge: return 36
        default: return 30
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: return 8
        case .small: return 10
        case .large, .extraLarge: return 18
        default: return 14
        }
    }

    private var fontSize: CGFloat {
        switch controlSize {
        case .mini: return 10
        case .small: return 11
        case .large, .extraLarge: return 14
        default: return 13
        }
    }
}

extension ButtonStyle where Self == SophiieButtonStyle {
    static var sophiiePrimary: SophiieButtonStyle { SophiieButtonStyle(kind: .primary) }
    static var sophiieSecondary: SophiieButtonStyle { SophiieButtonStyle(kind: .secondary) }
    static var sophiiePrimaryOnDark: SophiieButtonStyle { SophiieButtonStyle(kind: .primaryOnDark) }
    static var sophiieSecondaryOnDark: SophiieButtonStyle { SophiieButtonStyle(kind: .secondaryOnDark) }
}
