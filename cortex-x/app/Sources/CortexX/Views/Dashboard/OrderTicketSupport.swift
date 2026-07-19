// Order-ticket math — pure, NaN-safe, testable. The DAS-class ticket is a
// thin view over these: dollar/percent sizing, notional & concentration,
// price-tick stepping, risk-per-share + reward:risk, and the flatten/reverse
// intent construction. Nothing here touches SwiftUI or the model — every
// function takes plain numbers so the view stays declarative and the math
// stays unit-tested. Design law: absent/garbage input yields nil (never a
// bogus number the UI would render as truth).

import Foundation

// MARK: - Sizing

/// Share-count sizing from the three fast modes (SHARES, $, % of buying
/// power) plus the qty-increment defaults. Equities round DOWN to whole
/// shares; crypto keeps fractional units.
enum OrderSizing {
    /// Default qty step for the +/- buttons: 100 shares for equities, 1 unit
    /// for crypto. Configurable in the ticket; these are the seeds.
    static let equityIncrement: Double = 100
    static let cryptoIncrement: Double = 1

    /// The % chips, as fractions of buying power.
    static let percentChips: [Double] = [0.25, 0.50, 0.75, 1.0]

    /// A single order's notional is "large" once it passes this fraction of
    /// equity — the ticket raises an ember concentration warning past it.
    static let warnFractionOfEquity: Double = 0.25

    static func defaultIncrement(whole: Bool) -> Double {
        whole ? equityIncrement : cryptoIncrement
    }

    /// Shares purchasable with `dollars` at `price`. `whole` floors to whole
    /// shares (equities); crypto keeps the fraction. nil when either input is
    /// not finite, price <= 0, or the result rounds to nothing.
    static func shares(dollars: Double, price: Double, whole: Bool) -> Double? {
        guard dollars.isFinite, price.isFinite, dollars > 0, price > 0 else { return nil }
        let raw = dollars / price
        let sized = whole ? raw.rounded(.down) : raw
        return sized > 0 ? sized : nil
    }

    /// Shares from a fraction of buying power (0.25 = 25%) at `price`. Routes
    /// through `shares` so the whole-vs-fractional rule is shared.
    static func sharesFromBuyingPower(
        fraction: Double, buyingPower: Double, price: Double, whole: Bool
    ) -> Double? {
        guard fraction.isFinite, buyingPower.isFinite, fraction > 0, buyingPower > 0
        else { return nil }
        return shares(dollars: fraction * buyingPower, price: price, whole: whole)
    }

    /// notional = |qty * price|. nil when either input is non-finite.
    static func notional(qty: Double, price: Double) -> Double? {
        guard qty.isFinite, price.isFinite else { return nil }
        return abs(qty * price)
    }

    /// The fraction of equity a notional represents. nil when equity <= 0 or
    /// any input is non-finite — a divide the UI must render as "—".
    static func fractionOfEquity(notional: Double, equity: Double) -> Double? {
        guard notional.isFinite, equity.isFinite, equity > 0 else { return nil }
        return notional / equity
    }
}

// MARK: - Compact readout

/// The dense ticket's one-line size + RISK readout, pre-formatted so the
/// share-count / notional / %-equity / risk / reward:risk strings and the
/// concentration flag are decided away from SwiftUI. NaN-safe by construction:
/// an absent or non-finite input becomes "—" (or an omitted optional segment),
/// never a bogus number the ticket would render as truth.
struct TicketReadout: Equatable {
    /// Resolved share count ("100 sh" / "— sh").
    var shares: String
    var notional: String
    var equityPct: String
    /// True once the order's notional passes the concentration threshold.
    var concentrated: Bool
    /// Total money at risk to the protective stop — nil unless a stop is set.
    var risk: String?
    /// Reward:risk ("1.80 : 1") — nil unless a positive, finite ratio exists.
    var rewardRisk: String?

    static func make(
        qty: Double?,
        notional: Double?,
        equityFraction: Double?,
        warnFraction: Double = OrderSizing.warnFractionOfEquity,
        totalRisk: Double?,
        rewardRisk: Double?
    ) -> TicketReadout {
        var riskStr: String?
        if let r = totalRisk, r.isFinite { riskStr = DashFormat.money(r) }
        var rrStr: String?
        if let rr = rewardRisk, rr.isFinite, rr > 0 { rrStr = String(format: "%.2f : 1", rr) }
        return TicketReadout(
            shares: qty.map { "\(DashFormat.qty($0)) sh" } ?? "— sh",
            notional: notional.map { DashFormat.money($0) } ?? "—",
            equityPct: equityFraction.map { DashFormat.pct($0) } ?? "—",
            concentrated: (equityFraction ?? 0) > warnFraction,
            risk: riskStr,
            rewardRisk: rrStr
        )
    }
}

// MARK: - Price ticks

/// Price stepping for the limit/stop arrow buttons. The tick scales with the
/// price band so a $43k crypto steps by whole dollars while a $5 stock steps
/// by a penny — mirroring the DashFormat precision ramp.
enum PriceTick {
    /// A sane tick for a price level. Non-finite / non-positive → 0.01.
    static func size(for price: Double) -> Double {
        guard price.isFinite else { return 0.01 }
        let a = abs(price)
        if a >= 10_000 { return 1 }
        if a >= 1_000 { return 0.5 }
        if a >= 100 { return 0.05 }
        if a >= 1 { return 0.01 }
        if a > 0 { return 0.001 }
        return 0.01
    }

    /// Step `price` by `ticks` increments of `tickSize`, clamped at 0 and
    /// rounded to the tick grid so float drift never leaks extra digits.
    /// Non-finite price falls back to a single tick from zero.
    static func step(price: Double, ticks: Int, tickSize: Double) -> Double {
        guard tickSize.isFinite, tickSize > 0 else { return max(price.isFinite ? price : 0, 0) }
        let base = price.isFinite ? price : 0
        let stepped = base + Double(ticks) * tickSize
        let clamped = max(stepped, 0)
        // Snap to the tick grid to kill accumulated binary-float error.
        return (clamped / tickSize).rounded() * tickSize
    }
}

// MARK: - Risk / reward

/// Per-share risk and reward:risk for the live RISK readout. Semantics are
/// referenced from where the market is now (the entry reference the caller
/// passes — typically last/mark price), the protective `stop`, and a `target`
/// (the limit acting as the profit target). All signed by trade side so a
/// stop or target on the wrong side reads honestly (<= 0) rather than
/// pretending to be protective.
enum OrderRisk {
    /// Signed loss per share from `entry` to the protective `stop`: a long
    /// loses entry-stop, a short loses stop-entry. Positive = the stop sits on
    /// the losing side (protective); <= 0 = the wrong side (no protection).
    /// nil when either input is non-finite.
    static func riskPerShare(side: Side, entry: Double, stop: Double) -> Double? {
        guard entry.isFinite, stop.isFinite else { return nil }
        return side == .buy ? entry - stop : stop - entry
    }

    /// Reward-to-risk. reward = the favorable distance from `entry` to
    /// `target` (long: target-entry, short: entry-target); risk = the
    /// protective distance to `stop`. nil unless risk is strictly positive and
    /// every input finite — the ratio is meaningless without real protection.
    /// A negative result (target on the wrong side) is returned as-is so the
    /// UI can decline to show it.
    static func rr(side: Side, entry: Double, stop: Double, target: Double) -> Double? {
        guard target.isFinite,
            let risk = riskPerShare(side: side, entry: entry, stop: stop),
            risk > 0
        else { return nil }
        let reward = side == .buy ? target - entry : entry - target
        guard reward.isFinite else { return nil }
        return reward / risk
    }
}

// MARK: - Position actions (flatten / reverse)

/// A sized order side — the atom returned by the flatten/reverse builders so
/// the ticket and its tests agree on the exact intent without a live model.
struct OrderAction: Equatable {
    let side: Side
    let qty: Double
}

/// Constructs the FLATTEN and REVERSE actions from a signed position size.
/// Both mirror the positions-table Close path (opposite side, market) — the
/// single source of truth for "unwind this symbol".
enum PositionAction {
    /// Below this the position is treated as flat (matches AppModel's own
    /// zero-position epsilon).
    static let flatEpsilon: Double = 1e-12

    /// Close a position: opposite side, the whole absolute size. nil when the
    /// position is already flat.
    static func flatten(positionQty qty: Double) -> OrderAction? {
        guard qty.isFinite, abs(qty) > flatEpsilon else { return nil }
        return OrderAction(side: qty > 0 ? .sell : .buy, qty: abs(qty))
    }

    /// Reverse a position: opposite side, DOUBLE the absolute size (close the
    /// current book and open the mirror in one market order). nil when flat.
    static func reverse(positionQty qty: Double) -> OrderAction? {
        guard qty.isFinite, abs(qty) > flatEpsilon else { return nil }
        return OrderAction(side: qty > 0 ? .sell : .buy, qty: abs(qty) * 2)
    }
}
