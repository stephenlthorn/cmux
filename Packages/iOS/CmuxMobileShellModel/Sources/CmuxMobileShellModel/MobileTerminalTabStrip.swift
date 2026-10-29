import Foundation

/// The tabs a workspace shows above its terminal on the phone: one per
/// terminal, in workspace order, with the one on screen marked. A workspace
/// with a single terminal has nothing to switch to, so it shows no strip.
public struct MobileTerminalTabStrip: Equatable, Sendable {
    /// One tab in the strip.
    public struct Tab: Identifiable, Equatable, Sendable {
        /// The terminal this tab switches to.
        public let id: MobileTerminalPreview.ID
        /// The terminal's display name.
        public let name: String
        /// Whether this terminal is the one on screen.
        public let isSelected: Bool
    }

    /// The tabs to draw, empty when the workspace has fewer than two terminals.
    public let tabs: [Tab]

    /// Builds the strip for a workspace's terminals.
    /// - Parameters:
    ///   - terminals: The workspace's terminals, in workspace order.
    ///   - selectedID: The terminal on screen. When it is no longer in
    ///     `terminals`, the first terminal is marked instead, matching what the
    ///     workspace shows.
    public init(terminals: [MobileTerminalPreview], selectedID: MobileTerminalPreview.ID?) {
        guard terminals.count > 1 else {
            tabs = []
            return
        }
        let selected = terminals.contains { $0.id == selectedID } ? selectedID : terminals.first?.id
        tabs = terminals.map { Tab(id: $0.id, name: $0.name, isSelected: $0.id == selected) }
    }
}
