// COMPANY v2 support: the pure, testable helpers behind the board's new
// panes — the STATISTICS block (client-side market cap + honest labels),
// the LATEST FILINGS ordering, and the COMPANY NEWS filter — plus the small
// shared chrome (statistic cell, filing row, news row) they render into.
//
// Everything here is scoped to the company board (Company*). Every helper is
// NaN-safe and honest: a missing input never fabricates a number, and a
// dollar value is never mislabeled as a share count.

import SwiftUI

// MARK: - Statistics (client-side market cap + honest labels)

enum CompanyStats {
    // Honest, single-source-of-truth labels/notes. Exposed so the view and the
    // tests read the same strings — the float is a DOLLAR value and its label
    // must never claim to be a share count.
    static let marketCapLabel = "market cap"
    static let marketCapNote = "shares × last price"
    static let sharesLabel = "shares out"
    static let sharesNote = "shares outstanding"
    static let floatLabel = "$ float"
    static let floatNote = "public float (USD, 10-K cover)"

    /// Market cap = shares_outstanding × last price, computed CLIENT-side.
    /// nil-safe: any nil, non-finite, or non-positive input yields nil — never
    /// 0, never a fabricated figure. The product is re-checked for overflow.
    static func marketCap(shares: Double?, lastPrice: Double?) -> Double? {
        guard let shares, shares.isFinite, shares > 0,
              let px = lastPrice, px.isFinite, px > 0 else { return nil }
        let cap = shares * px
        return cap.isFinite ? cap : nil
    }

    /// Abbreviated share COUNT: 24.6B / 890M / 12.5K / 950. No `$` — this is a
    /// count, never money. nil / non-finite → em dash (never 0). Mirrors the
    /// abbrevMoney thresholds so the two read consistently side by side.
    static func abbrevCount(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let a = abs(v)
        let sign = v < 0 ? "-" : ""
        func fmt(_ x: Double, _ suffix: String) -> String {
            let s: String
            if x >= 100 { s = String(format: "%.0f", x) }
            else if x >= 10 { s = String(format: "%.1f", x) }
            else { s = String(format: "%.2f", x) }
            return sign + s + suffix
        }
        if a >= 1e12 { return fmt(a / 1e12, "T") }
        if a >= 1e9 { return fmt(a / 1e9, "B") }
        if a >= 1e6 { return fmt(a / 1e6, "M") }
        if a >= 1e3 { return fmt(a / 1e3, "K") }
        return sign + a.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }
}

// MARK: - Filings ordering

enum CompanyFilings {
    /// Newest-first by filed date. "YYYY-MM-DD" sorts lexically the same as
    /// chronologically, so string comparison is exact; ties break on form then
    /// url for a stable order. The engine already sorts, but a mis-ordered
    /// payload still renders correctly.
    static func ordered(_ filings: [Filing]) -> [Filing] {
        filings.sorted {
            if $0.filed != $1.filed { return $0.filed > $1.filed }
            if $0.form != $1.form { return $0.form < $1.form }
            return $0.primary_doc_url < $1.primary_doc_url
        }
    }
}

// MARK: - Company news filter

enum CompanyNews {
    /// Corporate suffixes stripped to derive the "core" name, so a headline
    /// that says "NVIDIA beats estimates" still matches "NVIDIA Corporation".
    private static let corporateSuffixes: Set<String> = [
        "corporation", "corp", "corp.", "inc", "inc.", "incorporated",
        "company", "co", "co.", "ltd", "ltd.", "limited", "plc", "llc",
        "holdings", "holding", "group", "sa", "ag", "nv",
    ]

    /// The registrable company name: the full name minus trailing corporate
    /// suffix tokens (and a leading "The"). Falls back to the trimmed full name
    /// when stripping would leave nothing.
    static func coreName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ",", with: " ")
        var tokens = cleaned.split(whereSeparator: { $0 == " " }).map(String.init)
        while let last = tokens.last, corporateSuffixes.contains(last.lowercased()) {
            tokens.removeLast()
        }
        if let first = tokens.first, first.lowercased() == "the" { tokens.removeFirst() }
        let core = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return core.isEmpty ? name.trimmingCharacters(in: .whitespaces) : core
    }

    /// Headlines relevant to one company: symbol-tagged to it (case-insensitive
    /// exact match on `item.symbol`) OR whose title mentions the company name
    /// (full name, or its core after stripping suffixes). Newest-first, capped.
    static func filter(
        _ items: [NewsItem], symbol: String, name: String, cap: Int = 8
    ) -> [NewsItem] {
        let sym = symbol.trimmingCharacters(in: .whitespaces)
        let nm = name.trimmingCharacters(in: .whitespaces)
        var out = items.filter { matchesSymbol($0, sym) || matchesName($0, nm) }
        out.sort { $0.ts_ms > $1.ts_ms }
        if cap >= 0, out.count > cap { out.removeLast(out.count - cap) }
        return out
    }

    private static func matchesSymbol(_ item: NewsItem, _ symbol: String) -> Bool {
        guard !symbol.isEmpty, let s = item.symbol else { return false }
        return s.caseInsensitiveCompare(symbol) == .orderedSame
    }

    private static func matchesName(_ item: NewsItem, _ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if containsWord(item.title, name) { return true }
        let core = coreName(name)
        // A degenerate 1-char core would over-match; require at least 2.
        guard core.count >= 2 else { return false }
        return containsWord(item.title, core)
    }

    /// Case-insensitive, word-boundary containment. Unlike a raw substring test
    /// this won't surface "PHP 8.4 released" for HP or "advisable" for Visa —
    /// the needle must sit on `\b` boundaries, so a short/common name can't
    /// match inside a larger word. Hyphens are boundaries, so "Coca-Cola" still
    /// matches. Empty needle → false.
    private static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b"
        return haystack.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - Statistic cell

/// One STATISTICS value: a small uppercase label, a mono value, and an
/// optional dim note that discloses the derivation/source. Em-dash values
/// render dim so an absent statistic never reads as an emphatic figure.
struct CompanyStatCell: View {
    let label: String
    let value: String
    var note: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Text(value)
                .numeric(size: 13, weight: .medium)
                .foregroundStyle(value == "—" ? Theme.dim : (tint ?? Theme.bone))
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Filing row

/// One filing: a hairline-outlined form badge, the filed date (mono), and a
/// trailing open glyph. Click opens the primary document through the shared
/// http(s) guard (openGeoURL) — EDGAR URLs are still treated as untrusted.
struct CompanyFilingRow: View {
    let filing: Filing
    @State private var hovering = false

    var body: some View {
        Button {
            openGeoURL(filing.primary_doc_url)
        } label: {
            HStack(spacing: 8) {
                Text(filing.form)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.chipRadius)
                            .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                    )
                Text(filing.filed)
                    .numeric(size: 11)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.ember : Theme.dim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Theme.panelHi : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}

// MARK: - Company news row

/// The NEWS feed row grammar, scoped to the company board: tone-colored
/// number, title, source badge + domain, relative time. Click opens the URL
/// through the shared http(s) guard. The symbol chip is dropped — every row
/// here already belongs to the inspected company.
struct CompanyNewsRow: View {
    let item: NewsItem
    let now: Date
    @State private var hovering = false

    private var toneColor: Color {
        // Sentiment ≠ money direction — green/red stay reserved for P&L/returns.
        // The +/- sign carries polarity; bone value, dim when zero/non-finite.
        guard item.tone.isFinite, item.tone != 0 else { return Theme.dim }
        return Theme.bone
    }

    private var toneText: String {
        item.tone.isFinite ? String(format: "%+.1f", item.tone) : "—"
    }

    var body: some View {
        Button {
            openGeoURL(item.url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(toneText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(toneColor)
                    Spacer(minLength: 4)
                    Text(IntelTime.relative(item.ts_ms, now: now))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    NewsSourceChip(label: NewsSourceBadge.label(item))
                    Text(item.source_domain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Theme.panelHi : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
    }
}
