import Foundation

/// The size a mirrored tmux window claims while a phone views it.
///
/// A mirror sizes its tmux window from the Mac pane that draws it, so a phone
/// looking at the same tab saw a Mac-width window cropped at its right edge.
/// While a phone views a single-pane window, the window claims the phone's
/// grid, never larger than the Mac pane's; when the phone leaves, the Mac's
/// grid comes back, or the size the window had before the phone when no Mac
/// pane has measured it (a tab the Mac is not showing). Split windows stay with
/// the Mac, because shrinking the window to one phone pane would squeeze every
/// pane in it.
public enum RemoteTmuxPhoneWindowClaim {
    /// - Parameters:
    ///   - phone: The smallest grid of the phones viewing the window, or nil when none does.
    ///   - mac: The grid of the Mac pane showing the window, or nil when no pane measured it.
    ///   - beforePhone: The size the window claimed before a phone took it over.
    ///   - paneCount: The number of tmux panes in the window.
    /// - Returns: The grid to claim, or nil to leave the window's size alone.
    public static func size(
        phone: (columns: Int, rows: Int)?,
        mac: (columns: Int, rows: Int)?,
        beforePhone: (columns: Int, rows: Int)?,
        paneCount: Int
    ) -> (columns: Int, rows: Int)? {
        guard paneCount == 1 else { return nil }
        guard let phone else { return mac ?? beforePhone }
        guard let mac else { return phone }
        return (min(phone.columns, mac.columns), min(phone.rows, mac.rows))
    }
}
