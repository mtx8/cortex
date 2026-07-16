// Pan / zoom / crosshair state for the chart, plus the AppKit scroll-wheel
// bridge SwiftUI lacks on macOS. All mutation happens on the main thread.

import AppKit
import Observation
import SwiftUI

/// Drawing tool armed on the chart. Anything but `.cursor` claims clicks
/// for anchor placement and suppresses pan-dragging.
enum ChartTool: String, CaseIterable {
    case cursor, trendline, hline, vline, rect, fib, measure

    var symbolName: String {
        switch self {
        case .cursor: "cursorarrow"
        case .trendline: "line.diagonal"
        case .hline: "minus"
        case .vline: "arrow.up.and.down"
        case .rect: "rectangle"
        case .fib: "point.topleft.down.curvedto.point.bottomright.up"
        case .measure: "ruler"
        }
    }

    var help: String {
        switch self {
        case .cursor: "cursor"
        case .trendline: "trendline"
        case .hline: "horizontal line"
        case .vline: "vertical line"
        case .rect: "rectangle"
        case .fib: "fib retracement"
        case .measure: "measure"
        }
    }

    /// Drawing kind an armed tool produces; nil for the cursor.
    var drawingKind: DrawingKind? {
        switch self {
        case .cursor: nil
        case .trendline: .trendline
        case .hline: .hline
        case .vline: .vline
        case .rect: .rect
        case .fib: .fib
        case .measure: .measure
        }
    }
}

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
    var showMACD = false
    /// Log10 price axis; the frame falls back to linear when any visible
    /// low (or overlay value) is <= 0.
    var logScale = false

    // Drawing tools
    /// Armed drawing tool; non-cursor tools claim clicks and suppress pan.
    var activeTool: ChartTool = .cursor
    /// Magnet mode: anchor prices snap to the clicked bar's nearest
    /// open/high/low/close (timestamps already snap per bar). A mode like
    /// the overlay toggles, not a tool — it survives series switches.
    var magnetMode = false
    /// First anchor of an in-progress two-point drawing (Esc cancels).
    var pendingAnchor: DrawingPoint?
    /// Drawing picked with the cursor tool; Delete removes it.
    var selectedDrawingID: UUID?

    private var dragAnchorOffset: Double?

    /// Live-follow keeps the right edge pinned to the newest bar.
    var isFollowing: Bool { rightOffset <= 0 }

    /// Arm a tool; clicking the active tool disarms back to cursor. Any
    /// switch abandons a half-placed anchor, and arming drops selection.
    func selectTool(_ tool: ChartTool) {
        activeTool = activeTool == tool ? .cursor : tool
        pendingAnchor = nil
        if activeTool != .cursor { selectedDrawingID = nil }
    }

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
    /// in time. Disengages live-follow while offset > 0. An armed drawing
    /// tool suppresses panning so anchor clicks stay put.
    func dragChanged(translationX: CGFloat, slotWidth: CGFloat, total: Int) {
        guard slotWidth > 0, total > 0, activeTool == .cursor else { return }
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

    /// Range preset (1y/2y/5y/all): show exactly the last `barCount` bars,
    /// pinned to the live edge. Clamped to the zoom bounds.
    func applyRange(barCount: Int) {
        barsVisible = min(
            max(Double(barCount), ChartMath.minVisibleBars), ChartMath.maxVisibleBars
        )
        resetToLive()
    }

    /// Double-click / 'live' chip: re-engage follow.
    func resetToLive() {
        dragAnchorOffset = nil
        isDragging = false
        rightOffset = 0
    }

    /// Symbol or interval switched: new series, back to the live edge with
    /// no armed tool, pending anchor or (now stale) drawing selection.
    func resetForNewSeries() {
        resetToLive()
        hover = nil
        activeTool = .cursor
        pendingAnchor = nil
        selectedDrawingID = nil
    }
}

// MARK: - Magnet snap

enum MagnetMath {
    /// `price` snapped to the nearest of the bar's open/high/low/close.
    /// Non-finite candidates are skipped; if every candidate is non-finite
    /// (or `price` itself is), the input comes back unchanged. Equidistant
    /// candidates resolve to the earliest in O-H-L-C order.
    static func snapPrice(_ price: Double, to bar: Bar) -> Double {
        guard price.isFinite else { return price }
        var best = price
        var bestDist = Double.infinity
        for candidate in [bar.open, bar.high, bar.low, bar.close] where candidate.isFinite {
            let dist = abs(candidate - price)
            if dist < bestDist {
                bestDist = dist
                best = candidate
            }
        }
        return best
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
