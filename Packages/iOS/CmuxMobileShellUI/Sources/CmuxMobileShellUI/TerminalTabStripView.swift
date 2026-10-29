#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// The row of tabs above a workspace's terminal, so its other terminals are one
/// tap away instead of hidden behind the terminal picker menu.
struct TerminalTabStripView: View {
    let strip: MobileTerminalTabStrip
    let terminalTheme: TerminalTheme
    let select: (MobileTerminalPreview.ID) -> Void

    var body: some View {
        HorizontalEdgeFadePillBar(
            contentInsets: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12),
            fadesLeadingEdge: true,
            accessibilityIdentifier: "MobileTerminalTabStrip"
        ) {
            EmptyView()
        } pills: {
            HStack(spacing: 6) {
                ForEach(Array(strip.tabs.enumerated()), id: \.element.id) { index, tab in
                    tabButton(tab, position: index + 1)
                }
            }
            .fixedSize()
        } trailing: {
            EmptyView()
        }
        .frame(height: 34)
        .padding(.vertical, 4)
        .background(terminalTheme.terminalBackgroundColor)
    }

    private func tabButton(_ tab: MobileTerminalTabStrip.Tab, position: Int) -> some View {
        Button {
            select(tab.id)
        } label: {
            Text(title(tab, position: position))
                .font(.subheadline.weight(tab.isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(tab.isSelected ? Color.white : terminalTheme.terminalChromeForegroundColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    tab.isSelected
                        ? Color.accentColor
                        : terminalTheme.terminalChromeForegroundColor.opacity(0.12),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab.isSelected ? .isSelected : [])
    }

    private func title(_ tab: MobileTerminalTabStrip.Tab, position: Int) -> String {
        let name = tab.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty else { return name }
        return String(
            format: L10n.string("mobile.terminal.tabStrip.untitled", defaultValue: "Tab %d"),
            position
        )
    }
}
#endif
