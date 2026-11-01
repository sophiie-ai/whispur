import AppKit
import SwiftUI

// Component kit for the Settings window. Every colour, radius and type size
// comes from `SophiieTheme`; the kit adds layout, not new tokens.

/// Layout constants shared by the kit.
enum SettingsMetrics {
    /// Side of the rounded icon tile at the start of a row.
    static let iconTile: CGFloat = 32
    /// Gap between the icon tile and the row text.
    static let iconGap: CGFloat = 12
    /// Vertical padding inside a row.
    static let rowPadding: CGFloat = 10
    /// Horizontal padding inside a card.
    static let cardPadding: CGFloat = 16
    /// Vertical gap between sections on a page.
    static let sectionSpacing: CGFloat = 18
    /// Readable width of a page's content column.
    static let pageWidth: CGFloat = 620
    /// Width of the sidebar.
    static let sidebarWidth: CGFloat = 232
    /// Leading inset that lines a divider up with the row text.
    static var textInset: CGFloat { iconTile + iconGap }
}

// MARK: - Page

/// Scrolling page body: a centred column at a readable width on the window
/// canvas.
struct SettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                content
            }
            .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, SettingsView.titleBarHeight + 6)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Large page title, an optional status pill, an optional subtitle, and one
/// trailing action.
struct PageHeader<Action: View>: View {
    let title: String
    let pill: String?
    let pillTone: HeaderPill.Tone
    let subtitle: String?
    let action: Action

    init(
        _ title: String,
        pill: String? = nil,
        pillTone: HeaderPill.Tone = .info,
        subtitle: String? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.pill = pill
        self.pillTone = pillTone
        self.subtitle = subtitle
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(SophiieTheme.Typography.titleTracking)
                        .foregroundStyle(SophiieTheme.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let pill {
                        HeaderPill(title: pill, tone: pillTone)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.bottom, 2)
    }
}

extension PageHeader where Action == EmptyView {
    init(_ title: String, pill: String? = nil, pillTone: HeaderPill.Tone = .info, subtitle: String? = nil) {
        self.init(title, pill: pill, pillTone: pillTone, subtitle: subtitle) { EmptyView() }
    }
}

/// Small pill next to a page title ("Ready", "42 terms").
struct HeaderPill: View {
    enum Tone {
        case info
        case warning
    }

    let title: String
    var tone: Tone = .info

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(SophiieTheme.Palette.hairline, lineWidth: 1))
            .fixedSize()
    }

    private var foreground: Color {
        tone == .info ? SophiieTheme.Palette.interactive : SophiieTheme.Palette.warning
    }

    private var fill: Color {
        switch tone {
        case .info: return SophiieTheme.Palette.surfaceSelected
        // A light tint keeps the warning text at 4.5:1 on the canvas.
        case .warning: return SophiieTheme.Palette.warning.opacity(colorScheme == .dark ? 0.14 : 0.08)
        }
    }
}

// MARK: - Section + card

/// A section label above its card(s).
struct SettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            if let footer {
                Text(footer)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Rounded, bordered card holding rows. The hero card (the master switch)
/// sits on the selected fill.
struct SettingsCard<Content: View>: View {
    let isHero: Bool
    let content: Content

    init(hero: Bool = false, @ViewBuilder content: () -> Content) {
        self.isHero = hero
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SophiieTheme.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .background(isHero ? SophiieTheme.Palette.surfaceSelected : SophiieTheme.Palette.surface, in: shape)
            .overlay(shape.strokeBorder(SophiieTheme.Palette.border, lineWidth: 1))
    }
}

/// Divider between rows inside a card, inset to the text column by default.
struct CardDivider: View {
    var leadingInset: CGFloat = SettingsMetrics.textInset

    var body: some View {
        Rectangle()
            .fill(SophiieTheme.Palette.border)
            .frame(height: 1)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

/// Free-form content inside a card, padded like a row.
struct CardContent<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}

// MARK: - Rows

/// Rounded icon tile at the start of a row.
struct IconTile: View {
    let systemName: String
    var tint: Color = SophiieTheme.Palette.interactive

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: SettingsMetrics.iconTile, height: SettingsMetrics.iconTile)
            .background(SophiieTheme.Palette.surfaceSelected, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon tile, title, subtitle, trailing accessory.
struct SettingsRow<Accessory: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    var iconTint: Color
    let accessory: Accessory

    init(
        icon: String?,
        title: String,
        subtitle: String? = nil,
        iconTint: Color = SophiieTheme.Palette.interactive,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.iconTint = iconTint
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
            if let icon {
                IconTile(systemName: icon, tint: iconTint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(SophiieTheme.Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(icon: String?, title: String, subtitle: String? = nil, iconTint: Color = SophiieTheme.Palette.interactive) {
        self.init(icon: icon, title: title, subtitle: subtitle, iconTint: iconTint) { EmptyView() }
    }
}

/// A whole row that navigates somewhere: chevron accessory, full-width hit
/// target.
struct SettingsLinkRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRow(icon: icon, title: title, subtitle: subtitle) {
                ChevronAccessory(value: value)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Date column + one truncated line of text.
struct HistoryRow: View {
    let date: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(date)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(SophiieTheme.Palette.muted)
                .lineLimit(1)
                .frame(width: SettingsMetrics.iconTile + 28, alignment: .leading)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Accessories

/// Trailing disclosure chevron, with an optional muted value before it.
struct ChevronAccessory: View {
    var value: String?

    var body: some View {
        HStack(spacing: 8) {
            if let value {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SophiieTheme.Palette.muted)
                .accessibilityHidden(true)
        }
    }
}

/// The native switch, tinted with the app accent.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(SophiieTheme.Palette.accent)
            .accessibilityLabel(label)
    }
}

/// One keyboard key.
struct KeycapView: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SophiieTheme.Palette.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 26)
            .background(SophiieTheme.Palette.surface, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous)
                    .strokeBorder(SophiieTheme.Palette.hairlineStrong, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                // A slightly heavier bottom edge reads as a physical key.
                RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous)
                    .fill(SophiieTheme.Palette.hairline)
                    .frame(height: 2)
                    .padding(.horizontal, 3)
            }
    }
}

/// Keys joined by "+" (chord) or "then" (sequence).
struct KeycapCombo: View {
    enum Join { case chord, sequence }

    let keys: [String]
    var join: Join = .chord

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text(join == .chord ? "+" : "then")
                        .font(.system(size: 11))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
                KeycapView(key: key)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: join == .chord ? " plus " : " then "))
    }
}

/// Small borderless icon button (remove, clear).
struct InlineIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SophiieTheme.Palette.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A native pop-up picker for a row's trailing edge.
///
/// A pop-up's natural width is its WIDEST option, so by default it is fixed
/// to that size. Pass `maxWidth` when the options are open-ended (device
/// names): the button then stays within that width and truncates the
/// selected title, while the opened menu still shows every option in full.
struct RowPicker<Value: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Value
    var maxWidth: CGFloat?
    let options: Options

    init(_ label: String, selection: Binding<Value>, maxWidth: CGFloat? = nil, @ViewBuilder options: () -> Options) {
        self.label = label
        _selection = selection
        self.maxWidth = maxWidth
        self.options = options()
    }

    var body: some View {
        let picker = Picker(label, selection: $selection) { options }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(label)
        if let maxWidth {
            picker
                .frame(maxWidth: maxWidth, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        } else {
            picker.fixedSize()
        }
    }
}

/// Inline accent text action ("Add shortcut").
struct TextAction: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(SophiieTheme.Palette.interactive)
        .contentShape(Rectangle())
    }
}

// MARK: - Sidebar

/// Sidebar entry on the always-midnight sidebar: icon, label, optional
/// badge, raised pill when selected.
struct SidebarItem: View {
    let title: String
    let icon: String
    var badge: String?
    var isSelected = false

    private typealias OnDark = SophiieTheme.Palette.OnDark

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(isSelected ? OnDark.accent : OnDark.muted)
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(OnDark.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(OnDark.onAccent)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(OnDark.accent, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                .fill(isSelected ? OnDark.raised : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
    }
}

/// Small group label inside the sidebar.
struct SidebarGroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SophiieTheme.Palette.OnDark.muted)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
