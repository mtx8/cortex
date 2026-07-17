// FILINGS support: the pure, testable helpers behind the dedicated SEC EDGAR
// filings desk — the form-type chip taxonomy (FilingFormFilter) and its
// prefix/complement matching, the filed-date range gate (FilingsDateRange),
// the byte-size abbreviator + the open-target resolver (FilingsSupport), and
// the small table sort (FilingsSort).
//
// Everything here is scoped to the filings desk (Filing*). Every helper is
// NaN/empty-safe and honest: an absent field is disclosed with an em dash,
// never fabricated, and an unparseable date is kept rather than silently
// dropped under a range gate.

import Foundation

// MARK: - Form-type filter (client-side chips)

/// The FILINGS form-type chips. Each chip narrows the loaded filings by form
/// prefix, client-side (the engine already returned the entity's filings).
/// ALL passes everything; OTHER is the complement of the named chips. Raw
/// string so the default/ordering are testable.
enum FilingFormFilter: String, CaseIterable, Identifiable {
    case all, k10, q10, k8, s1, def14a, form4, sched13, form13f, other

    var id: String { rawValue }

    /// The chip label as rendered.
    var title: String {
        switch self {
        case .all: "ALL"
        case .k10: "10-K"
        case .q10: "10-Q"
        case .k8: "8-K"
        case .s1: "S-1"
        case .def14a: "DEF 14A"
        case .form4: "4"
        case .sched13: "13D/G"
        case .form13f: "13F"
        case .other: "OTHER"
        }
    }

    /// A longer tooltip for the terse chips.
    var help: String {
        switch self {
        case .all: "every form"
        case .k10: "annual report (10-K, 10-K/A)"
        case .q10: "quarterly report (10-Q, 10-Q/A)"
        case .k8: "material event (8-K, 8-K/A)"
        case .s1: "registration (S-1, S-1/A)"
        case .def14a: "proxy statement (DEF 14A)"
        case .form4: "insider transaction (Form 4, 4/A)"
        case .sched13: "beneficial ownership (SC 13D / 13G)"
        case .form13f: "institutional holdings (13F-HR / 13F-NT)"
        case .other: "none of the named forms"
        }
    }

    /// True when a filing's form belongs to this chip. Uppercased once; the
    /// named chips match on the exact form or its amendment suffix ("10-K"
    /// matches "10-K" and "10-K/A" but never "10-K405" or "40-F"). OTHER is
    /// the exact complement of the named set.
    func matches(_ form: String) -> Bool {
        let f = form.trimmingCharacters(in: .whitespaces).uppercased()
        switch self {
        case .all: return true
        case .k10: return Self.baseMatch(f, "10-K")
        case .q10: return Self.baseMatch(f, "10-Q")
        case .k8: return Self.baseMatch(f, "8-K")
        case .s1: return Self.baseMatch(f, "S-1")
        case .def14a: return Self.baseMatch(f, "DEF 14A")
        case .form4: return Self.baseMatch(f, "4")
        // 13D / 13G filings are "SC 13D" / "SC 13G" (+ "/A"); a contains test
        // catches the amendments and the bare variants without over-matching.
        case .sched13: return f.contains("13D") || f.contains("13G")
        case .form13f: return f.hasPrefix("13F")
        case .other: return !Self.namedMatch(f)
        }
    }

    /// Exact form, or the same form as an amendment ("10-K/A"). Deliberately
    /// NOT a raw prefix — a prefix would fold "40-F" into "4" and "10-K405"
    /// into "10-K".
    static func baseMatch(_ form: String, _ base: String) -> Bool {
        form == base || form.hasPrefix(base + "/")
    }

    /// True when any NAMED chip (not ALL, not OTHER) claims this form — the
    /// set OTHER is the complement of. `form` is expected pre-uppercased.
    static func namedMatch(_ form: String) -> Bool {
        allCases.contains { $0 != .all && $0 != .other && $0.matches(form) }
    }
}

// MARK: - Filed-date range gate

/// A trailing filed-date window over the loaded filings. YTD is calendar-year-
/// to-date; 1Y/5Y are trailing spans; ALL removes the gate. Raw string so the
/// default/ordering are testable.
enum FilingsDateRange: String, CaseIterable, Identifiable {
    case all, ytd, y1, y5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "ALL"
        case .ytd: "YTD"
        case .y1: "1Y"
        case .y5: "5Y"
        }
    }

    var help: String {
        switch self {
        case .all: "every filed date"
        case .ytd: "filed this calendar year"
        case .y1: "filed in the trailing year"
        case .y5: "filed in the trailing five years"
        }
    }

    /// The inclusive cutoff instant (UTC): a filing filed on/after this passes.
    /// nil = no gate (ALL). `now` is injected for tests.
    func cutoff(now: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        switch self {
        case .all:
            return nil
        case .ytd:
            let comps = cal.dateComponents([.year], from: now)
            return cal.date(from: DateComponents(year: comps.year, month: 1, day: 1))
        case .y1:
            return cal.date(byAdding: .year, value: -1, to: cal.startOfDay(for: now))
        case .y5:
            return cal.date(byAdding: .year, value: -5, to: cal.startOfDay(for: now))
        }
    }

    /// True when a "YYYY-MM-DD" filed date passes this range. An unparseable
    /// (or empty) date is KEPT — a formatting quirk must never hide a real
    /// filing. `now` is injected for tests.
    func contains(_ filed: String, now: Date) -> Bool {
        guard let cutoff = cutoff(now: now) else { return true }
        guard let d = FilingsSupport.parseDay(filed) else { return true }
        return d >= cutoff
    }
}

// MARK: - Table sort

/// One sort order over the filings table. Only FORM and FILED sort; FILED is
/// the calm default (newest first). Ties break so the order is stable across
/// republishes.
struct FilingsSort: Equatable {
    enum Column: String { case form, filed }
    var column: Column
    var ascending: Bool

    /// The default view: newest filed first.
    static let `default` = FilingsSort(column: .filed, ascending: false)

    func apply(_ rows: [FilingEntry]) -> [FilingEntry] {
        switch column {
        case .filed:
            // "YYYY-MM-DD" sorts lexically the same as chronologically.
            return rows.sorted {
                $0.filed == $1.filed
                    ? $0.accession > $1.accession
                    : (ascending ? $0.filed < $1.filed : $0.filed > $1.filed)
            }
        case .form:
            return rows.sorted {
                $0.form == $1.form
                    ? $0.filed > $1.filed
                    : (ascending ? $0.form < $1.form : $0.form > $1.form)
            }
        }
    }

    /// Repeat click flips direction; the first click on a column opens on its
    /// useful direction (dates newest-first, forms A-first).
    static func toggling(_ current: FilingsSort, column: Column) -> FilingsSort {
        if current.column == column {
            return FilingsSort(column: column, ascending: !current.ascending)
        }
        return FilingsSort(column: column, ascending: column == .form)
    }
}

// MARK: - Formatting & composition

enum FilingsSupport {
    /// Strict "YYYY-MM-DD" at UTC midnight; anything else is nil.
    static func parseDay(_ s: String) -> Date? {
        dayFormatter.date(from: s)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    /// Abbreviated byte size: "1.5 MB", "850 KB", "512 B". 0 (unknown) → em
    /// dash — an unknown size never reads as an emphatic zero. Decimal (1000)
    /// units so the math stays legible.
    static func size(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        let b = Double(bytes)
        if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.1f MB", b / 1e6) }
        if b >= 1e3 { return String(format: "%.0f KB", b / 1e3) }
        return "\(bytes) B"
    }

    /// The URL a row opens: the primary document when present, otherwise the
    /// filing index page (a lean payload with no primary_doc still resolves to
    /// something openable). May be "" when neither is known — the caller's
    /// http(s) guard then simply refuses.
    static func openTarget(_ e: FilingEntry) -> String {
        e.primary_doc_url.isEmpty ? e.filing_index_url : e.primary_doc_url
    }

    /// The rows the operator actually sees: form-chip + date-range filtered,
    /// then sorted. Full-text (`text`) is a SERVER-side re-request, never a
    /// client filter, so it plays no part here. `now` is injected for tests.
    static func visible(
        _ filings: [FilingEntry],
        form: FilingFormFilter,
        range: FilingsDateRange,
        sort: FilingsSort,
        now: Date
    ) -> [FilingEntry] {
        let filtered = filings.filter {
            form.matches($0.form) && range.contains($0.filed, now: now)
        }
        return sort.apply(filtered)
    }
}
