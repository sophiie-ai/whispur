import SwiftUI

extension EnvironmentValues {
    /// Renders onboarding's entrance animations at their end state. Renders
    /// and tests set it; the live window never does.
    @Entry var onboardingStillFrames = false
    /// Draws onboarding as Reduce Motion would, whatever the system says.
    /// Renders only: the system setting can't be overridden in a test.
    @Entry var onboardingRendersReducedMotion = false
}

/// The ready screen's picture of where Whispur lives: a quiet strip of menu
/// bar with Whispur's own glyph arriving on a soft glow, then the one thing
/// to remember. Staggered in; with Reduce Motion it only fades.
struct OnboardingMenuBarPreview: View {
    private typealias Palette = SophiieTheme.Palette

    /// "Hold Fn anywhere, then talk." or the toggle equivalent.
    let caption: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingStillFrames) private var stillFrames

    @State private var showsStrip = false
    @State private var showsGlyph = false
    @State private var showsCaption = false
    @State private var glows = false

    var body: some View {
        VStack(spacing: 22) {
            strip
            Text(caption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
                .opacity(showsCaption ? 1 : 0)
                .offset(y: showsCaption || reduceMotion ? 0 : 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Whispur is in your menu bar. \(caption)")
        .onAppear(perform: enter)
    }

    private var strip: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.OnDark.muted)
            ForEach(["File", "Edit", "View"], id: \.self) { item in
                Text(item)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.OnDark.muted.opacity(0.8))
            }
            Spacer(minLength: 12)
            glyph
            Image(systemName: "wifi")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.OnDark.muted)
            Image(systemName: "battery.75percent")
                .font(.system(size: 12))
                .foregroundStyle(Palette.OnDark.muted)
            Text("9:41")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.OnDark.inkSecondary)
        }
        .padding(.horizontal, 14)
        .frame(width: 400, height: 30)
        .background(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                .strokeBorder(Palette.OnDark.hairline, lineWidth: 1)
        )
        // Fade the strip's left edge into the stage: it's a glimpse, not a
        // replica of the whole menu bar.
        .mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.32)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .opacity(showsStrip ? 1 : 0)
        .offset(y: showsStrip || reduceMotion ? 0 : -6)
    }

    /// The status item's own template image, so it matches the menu bar.
    private var glyph: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Palette.sky.opacity(0.55), Palette.sky.opacity(0)],
                        center: .center,
                        startRadius: 1,
                        endRadius: 22
                    )
                )
                .frame(width: 44, height: 44)
                .opacity(glows ? 1 : 0)
                .scaleEffect(glows || reduceMotion ? 1 : 0.6)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(showsGlyph ? 0.14 : 0))
                .frame(width: 26, height: 22)
            Image("MenuBarGlyph")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(Palette.OnDark.ink)
        }
        .frame(width: 26, height: 22)
        .opacity(showsGlyph ? 1 : 0)
        .scaleEffect(showsGlyph || reduceMotion ? 1 : 0.7)
        .offset(y: showsGlyph || reduceMotion ? 0 : 4)
    }

    private func enter() {
        if stillFrames {
            showsStrip = true
            showsGlyph = true
            showsCaption = true
            glows = true
            return
        }
        // Reduce Motion keeps the order but only fades.
        let ease: (Double) -> Animation = { reduceMotion ? .easeOut(duration: 0.25).delay($0) : SophiieTheme.Motion.emphasized(0.45).delay($0) }
        withAnimation(ease(0.10)) { showsStrip = true }
        withAnimation(ease(0.45)) { showsGlyph = true }
        withAnimation(reduceMotion ? ease(0.45) : .easeOut(duration: 0.9).delay(0.55)) { glows = true }
        withAnimation(ease(0.85)) { showsCaption = true }
    }
}
