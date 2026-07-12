// Pan / zoom / crosshair state for the chart, plus the AppKit scroll-wheel
// bridge SwiftUI lacks on macOS. All mutation happens on the main thread.

import AppKit
import Observation
import SwiftUI

@Observable
final class ChartInteraction {
    /// Window width in bar slots (20...1500).
    var barsVisible: Double = ChartMath.defaultVisibleBars
    /// Bars the right edge sits behind the latest bar; 0 = live-follow.
    var rightOffset: Double = 0
    /// Cursor position in chart-local coordinates, nil when outside.
    var hover: CGPoint?
    var isDragging = false

    // Overlay toggles
    var showEMA9 = true
    var showEMA21 = true
    var showEMA50 = true
    var showBollinger = true
    var showRSI = true

    private var dragAnchorOffset: Double?

    /// Live-follow keeps the right edge pinned to the newest bar.
    var isFollowing: Bool { rightOffset <= 0 }

    /// Scroll zoom. Positive delta zooms in. While following, the anchor is
    /// the live edge; otherwise the bar under the cursor holds its position.
    func zoom(scrollDeltaY: Double, anchorFraction: Double, total: Int) {
        guard total > 0, scrollDeltaY != 0 else { return }
        let factor = exp(-scrollDeltaY * 0.01)
        let anchor = isFollowing ? 1.0 : anchorFraction
        let z = ChartMath.zoom(
            barsVisible: barsVisible, rightOffset: rightOffset,
            factor: factor, anchor: anchor, total: total
        )
        barsVisible = z.barsVisible
        rightOffset = z.rightOffset
    }

    /// Drag pans: content follows the pointer, so dragging right walks back
    /// in time. Disengages live-follow while offset > 0.
    func dragChanged(translationX: CGFloat, slotWidth: CGFloat, total: Int) {
        guard slotWidth > 0, total > 0 else { return }
        isDragging = true
        let anchor = dragAnchorOffset ?? rightOffset
        dragAnchorOffset = anchor
        rightOffset = ChartMath.clampOffset(
            anchor + Double(translationX) / Double(slotWidth),
            total: total, barsVisible: barsVisible
        )
    }

    func dragEnded() {
        isDragging = false
        dragAnchorOffset = nil
        if rightOffset < 1 { rightOffset = 0 } // snap back onto the live edge
    }

    /// Double-click / 'live' chip: re-engage follow.
    func resetToLive() {
        dragAnchorOffset = nil
        isDragging = false
        rightOffset = 0
    }

    /// Symbol or interval switched: new series, back to the live edge.
    func resetForNewSeries() {
        resetToLive()
        hover = nil
    }
}

// MARK: - Scroll-wheel bridge

/// Invisible AppKit layer reporting scroll-wheel deltas. Hit-testing stays
/// transparent (`hitTest` returns nil) so SwiftUI gestures underneath keep
/// working; a local event monitor picks up scrolls landing inside the view.
struct ScrollWheelCatcher: NSViewRepresentable {
    /// (scrollingDeltaY, location in top-left-origin view coordinates)
    var onScroll: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((Double, CGPoint) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    let p = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(p) else { return event }
                    let flipped = CGPoint(
                        x: p.x,
                        y: self.isFlipped ? p.y : self.bounds.height - p.y
                    )
                    self.onScroll?(event.scrollingDeltaY, flipped)
                    return nil // consumed
                }
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
