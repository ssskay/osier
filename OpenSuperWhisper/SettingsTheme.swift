import SwiftUI
import AppKit

/// Design tokens for the Settings window.
///
/// These are now **aliases onto `Osier`** — the brand palette is the single source of colour
/// for the app, and this enum exists so the many `STheme.…` call sites keep working. Add new
/// colours to `Osier`, not here.
///
/// The one substantive change from the previous "Atelier" direction: the accent was copper
/// `#E8734A`, used decoratively on toggles, focus rings and section marks. That sits a hair
/// away from the brand's rust, and rust has exactly one job now — *recording*. A rust-adjacent
/// tint scattered through Settings would drain that signal of meaning, so the accent is willow
/// leaf green and rust appears nowhere in this window.
enum STheme {
    /// Willow leaf — the app accent. Green, so that rust stays reserved.
    static let accent = Osier.mark
    static let accentSoft = Osier.markWash

    static let windowBg  = Osier.surface
    static let sidebarBg = Osier.surfaceSunken
    static let border    = Osier.hairlineSoft
    static let cardBg    = Osier.surfaceRaised
    static let inputBg   = Osier.surfaceSunken
    static let controlBg = Osier.surfaceRaised
    static let controlBorder = Osier.hairline

    static let text      = Osier.ink
    static let textBright = Osier.inkBright
    static let hint      = Osier.inkFaint
    static let sectionTitle = Osier.inkFaint
    static let sidebarItem = Osier.inkSoft

    static let warn      = Osier.caution
    static let warnBg    = Osier.cautionWash
    static let warnBorder = Osier.cautionBorder
    static let ok        = Osier.success
    static let okBg      = Osier.successWash
}

// MARK: - Reusable pieces

/// Uppercase section header with a trailing hairline, per the design.
struct SSectionHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(STheme.sectionTitle)
            Rectangle().fill(STheme.border).frame(height: 1)
        }
    }
}

/// One settings row: title (+ optional hint under it) on the left, control on the right.
struct SRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil
    var hintColor: Color = STheme.hint
    var indented = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(STheme.text)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundColor(hintColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, indented ? 16 : 0)
        .frame(minHeight: 26)
    }
}

/// Small bordered ALL-CAPS tag ("PARAKEET ONLY", "ADVANCED", …).
struct STag: View {
    let label: LocalizedStringKey
    init(_ label: LocalizedStringKey) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundColor(STheme.hint)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(STheme.controlBorder, lineWidth: 1))
    }
}

/// Amber callout for permission warnings and destructive notices.
struct SWarnBox<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .font(.system(size: 11.5))
            .foregroundColor(STheme.warn)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(STheme.warnBg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.warnBorder, lineWidth: 1))
    }
}

/// Copper-tinted switch, sized like the design's compact toggles.
struct SToggle: View {
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(SwitchToggleStyle(tint: STheme.accent))
            .labelsHidden()
            .controlSize(.small)
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
    }
}

/// A settings pane: consistent title header + scrollable sectioned body.
struct SPane<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(STheme.textBright)
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundColor(STheme.hint)
                }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .background(STheme.windowBg)
    }
}

/// A titled group of rows with the hairline header.
struct SSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SSectionHeader(title)
            content()
        }
    }
}
