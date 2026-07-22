// Shared right-rail width for the center column. The chart TRADING DOCK (top)
// and the deck ORDER-TICKET column (bottom) form ONE continuous vertical band on
// the right of the center column — same width, same seam, edges flush. Both
// their resize dividers drive this single source of truth so dragging either one
// moves the whole rail in lockstep; each row still commits the final width once
// to @AppStorage("chartDockWidth") on release (so persistence + smooth resize are
// preserved). `drag` is non-nil only WHILE a divider is being dragged.

import SwiftUI

@Observable
final class RailLayout {
    /// Live width during a drag of either divider; nil when not dragging.
    var drag: Double?

    /// The rail width to render right now: the live drag value if a divider is
    /// active, else the persisted width — both clamped to the chart-dock bounds.
    func width(persisted: Double) -> CGFloat {
        CGFloat(ResizablePanel.chartDock.clamp(drag ?? persisted))
    }
}
