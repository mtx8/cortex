// FILINGS — the dedicated SEC EDGAR desk. Search a ticker or company, pull its
// filings straight from EDGAR, and read them in a dense table: form badge,
// filed date, period, description, size, doc link. Form-type chips and a
// filed-date range filter the loaded set client-side; a full-text keyword
// field re-requests the engine's EDGAR full-text search. Every row traces to a
// disclosed source (data.sec.gov / efts.sec.gov); an honest note surfaces
// whenever a pull was partial or an entity went unresolved. The pure, testable
// models live in FilingsSupport.swift.

import SwiftUI

// MARK: - Column layout (fixed widths so header + rows stay aligned)

private enum FilingsCol {
    static let form: CGFloat = 96
    static let filed: CGFloat = 92
    static let period: CGFloat = 92
    static let size: CGFloat = 78
    static let action: CGFloat = 24
    static let gap: CGFloat = 12
    // DESCRIPTION flexes to the leftover pane width.
}

// MARK: - View

struct FilingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var fullText = ""
    @State private var form: FilingFormFilter = .all
    @State private var range: FilingsDateRange = .all
    @State private var sort: FilingsSort = .default

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                if let note = model.filingsReport?.note, !note.isEmpty {
                    noteStrip(note)
                }
                Divider().overlay(Theme.line)
                filterRow
                Divider().overlay(Theme.line)
                Group {
                    if let report = model.filingsReport {
                        board(report, now: context.date)
                    } else if model.filingsLoading {
                        loadingState
                    } else {
                        emptyState
                    }
                }
                // topLeading so a table shorter/narrower than the pane hugs the
                // corner and grows from there — never floats dead-center.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        // Reflect the active symbol in the search field when arriving via
        // openFilings (COMPANY board). Only mirrors state — never re-requests.
        .task(id: model.filingsQuery) {
            if !model.filingsQuery.isEmpty { query = model.filingsQuery }
        }
    }

    // MARK: Actions

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        model.requestFilings(query: q, text: fullText.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Header

    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            SectionLabel(text: "filings")
            searchField
            if model.filingsLoading {
                ProgressView().controlSize(.mini).tint(Theme.ember)
            }
            Spacer(minLength: 8)
            if let report = model.filingsReport {
                resolvedEntity(report)
                sourceMeta(report, now: now)
            } else {
                Text("SEC EDGAR")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            TextField("ticker or company", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .onSubmit(submit)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 220)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
        .help("search a ticker or company, then Return — filings come straight from SEC EDGAR")
    }

    /// Resolved entity: name (bone), ticker (mono), and CIK — shown only for a
    /// resolved report. An unresolved pull leaves name empty; the honest note
    /// strip carries the explanation instead.
    @ViewBuilder
    private func resolvedEntity(_ report: FilingsReport) -> some View {
        if !report.name.isEmpty {
            HStack(spacing: 8) {
                Text(report.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                if !report.ticker.isEmpty {
                    Text(report.ticker)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
                if !report.cik.isEmpty {
                    Text("CIK \(report.cik)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Source label + relative timestamp — shown only for a RESOLVED report
    /// (non-empty CIK). An unresolved pull performs no submissions fetch, so
    /// surfacing "data.sec.gov" + a fresh timestamp would imply a provenance
    /// that does not exist; the note strip carries the honest truth instead.
    @ViewBuilder
    private func sourceMeta(_ report: FilingsReport, now: Date) -> some View {
        if !report.cik.isEmpty {
            HStack(spacing: 8) {
                if !report.source.isEmpty {
                    Text(report.source)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                if report.ts_ms > 0 {
                    Text(IntelTime.relative(report.ts_ms, now: now))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }

    /// Honest disclosure: whatever the engine reported went wrong or partial
    /// ("ticker not found in SEC map", "fetch failed", …). An ember dot marks
    /// attention without a colored warning fill (design law).
    private func noteStrip(_ note: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.ember)
                .frame(width: 4, height: 4)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: Filter row (form chips · date range · full-text)

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(FilingFormFilter.allCases) { f in
                    formChip(f)
                }
                Spacer(minLength: 8)
                if let count = visibleCountLabel {
                    Text(count)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                rangeSegment
                Spacer(minLength: 8)
                fullTextField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func formChip(_ f: FilingFormFilter) -> some View {
        let active = form == f
        return Button {
            form = f
        } label: {
            Text(f.title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(active ? Theme.ember : Theme.dim)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(active ? Theme.emberTint : Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .strokeBorder(active ? Theme.ember.opacity(0.5) : Theme.line,
                                      lineWidth: Theme.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(f.help)
        .animation(DeckMotion.ease(), value: active)
    }

    private var rangeSegment: some View {
        HStack(spacing: 2) {
            ForEach(FilingsDateRange.allCases) { r in
                let on = range == r
                Button {
                    range = r
                } label: {
                    Text(r.title)
                        .font(.system(size: 10, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.bone : Theme.dim)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(on ? Theme.panelHi : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(r.help)
                .animation(DeckMotion.ease(), value: on)
            }
        }
        .padding(2)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
    }

    private var fullTextField: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            TextField("full-text keywords", text: $fullText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .frame(width: 180)
                .onSubmit(submit)
            if !fullText.isEmpty {
                Button {
                    fullText = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("clear keywords")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(Theme.line, lineWidth: Theme.hairline)
        )
        .help("EDGAR full-text search (efts.sec.gov) — Return to run against the current entity")
    }

    /// "N of M" once a report with filings is present.
    private var visibleCountLabel: String? {
        guard let report = model.filingsReport, !report.filings.isEmpty else { return nil }
        let shown = FilingsSupport.visible(
            report.filings, form: form, range: range, sort: sort,
            now: Date()
        ).count
        return "\(shown) of \(report.filings.count)"
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.ember)
            Text("pulling filings from EDGAR…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("search a ticker to pull its SEC filings — straight from EDGAR")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text("submissions from data.sec.gov · add keywords for full-text search (efts.sec.gov)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Board (the table)

    @ViewBuilder
    private func board(_ report: FilingsReport, now: Date) -> some View {
        let rows = FilingsSupport.visible(
            report.filings, form: form, range: range, sort: sort, now: now
        )
        if report.filings.isEmpty {
            // The engine returned no filings — a note (if any) already
            // disclosed why in the strip above.
            noFilings(report)
        } else if rows.isEmpty {
            noRowsForFilter
        } else {
            table(rows)
        }
    }

    private func noFilings(_ report: FilingsReport) -> some View {
        VStack(spacing: 8) {
            Text(report.name.isEmpty
                ? "no filings — nothing resolved from EDGAR"
                : "no filings on record for \(report.name)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
            Text("sourced from SEC EDGAR (data.sec.gov)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noRowsForFilter: some View {
        VStack(spacing: 8) {
            Text("no filings match this filter")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Text("relax the '\(form.title)' form filter or the '\(range.title)' date range")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func table(_ rows: [FilingEntry]) -> some View {
        // Vertical-only scroll: the columns fit any standard pane, so header
        // and rows span its full width (DESCRIPTION flexes) rather than riding
        // a narrow horizontally-scrolling island.
        ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { entry in
                        FilingRow(entry: entry)
                    }
                } header: {
                    headerRow
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: FilingsCol.gap) {
            sortableHeader("form", column: .form, width: FilingsCol.form, alignment: .leading)
            sortableHeader("filed", column: .filed, width: FilingsCol.filed, alignment: .leading)
            headerLabel("period", width: FilingsCol.period, alignment: .leading)
            headerLabel("description", width: nil, alignment: .leading)
            headerLabel("size", width: FilingsCol.size, alignment: .trailing)
            Color.clear.frame(width: FilingsCol.action, height: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink)
        .deckRowRule(1)
    }

    private func sortableHeader(
        _ title: String, column: FilingsSort.Column, width: CGFloat, alignment: Alignment
    ) -> some View {
        let active = sort.column == column
        return Button {
            sort = FilingsSort.toggling(sort, column: column)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(active ? Theme.ember : Theme.dim)
                    .lineLimit(1)
                if active {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.ember)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DeckMotion.ease(), value: active)
    }

    private func headerLabel(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        HStack(spacing: 0) {
            if alignment == .trailing { Spacer(minLength: 0) }
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            if alignment == .leading { Spacer(minLength: 0) }
        }
        .frame(
            minWidth: width,
            maxWidth: width ?? .infinity,
            alignment: alignment
        )
    }
}

// MARK: - Row

/// One filing: a hairline-outlined form badge, filed + period (mono), the
/// flexible description with a dim "xbrl" tag and any 8-K item codes, the
/// abbreviated size, and a trailing open glyph. Click opens the primary
/// document (or the index page when the primary is empty) through the shared
/// http(s) guard — EDGAR URLs are still treated as untrusted network data.
private struct FilingRow: View {
    let entry: FilingEntry
    @State private var hovering = false

    var body: some View {
        Button {
            openGeoURL(FilingsSupport.openTarget(entry))
        } label: {
            HStack(spacing: FilingsCol.gap) {
                formBadge
                Text(entry.filed.isEmpty ? "—" : entry.filed)
                    .numeric(size: 11)
                    .foregroundStyle(entry.filed.isEmpty ? Theme.dim : Theme.bone)
                    .lineLimit(1)
                    .frame(width: FilingsCol.filed, alignment: .leading)
                Text(entry.report_date.isEmpty ? "—" : entry.report_date)
                    .numeric(size: 11)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .frame(width: FilingsCol.period, alignment: .leading)
                descriptionCell
                Text(FilingsSupport.size(entry.size))
                    .numeric(size: 11)
                    .foregroundStyle(entry.size > 0 ? Theme.bone : Theme.dim)
                    .lineLimit(1)
                    .frame(width: FilingsCol.size, alignment: .trailing)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.ember : Theme.dim)
                    .frame(width: FilingsCol.action, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Theme.panelHi : .clear)
            .deckRowRule()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
        .help(helpText)
    }

    private var formBadge: some View {
        Text(entry.form.isEmpty ? "—" : entry.form)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.bone)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(width: FilingsCol.form, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                    .frame(width: badgeWidth)
            }
    }

    /// The badge outline hugs the form text rather than the full column, so a
    /// short form ("4") doesn't wear an oversized box.
    private var badgeWidth: CGFloat {
        let base = CGFloat((entry.form.isEmpty ? 1 : entry.form.count)) * 7 + 14
        return min(base, FilingsCol.form)
    }

    private var descriptionCell: some View {
        HStack(spacing: 6) {
            Text(entry.description.isEmpty ? "—" : entry.description)
                .font(.system(size: 11))
                .foregroundStyle(entry.description.isEmpty ? Theme.dim : Theme.bone)
                .lineLimit(1)
                .truncationMode(.tail)
            if !entry.items.isEmpty {
                Text(entry.items)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            if entry.is_xbrl {
                Text("xbrl")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.chipRadius)
                            .strokeBorder(Theme.line, lineWidth: Theme.hairline)
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var helpText: String {
        var parts: [String] = []
        if !entry.form.isEmpty { parts.append(entry.form) }
        if !entry.description.isEmpty { parts.append(entry.description) }
        if !entry.accession.isEmpty { parts.append("accession \(entry.accession)") }
        let target = FilingsSupport.openTarget(entry)
        parts.append(target.isEmpty ? "no document link" : "open \(target)")
        return parts.joined(separator: " · ")
    }
}
