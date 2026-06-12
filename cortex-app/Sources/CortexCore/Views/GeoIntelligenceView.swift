import SwiftUI

/// Geo-Intelligence tab — the physical-alpha command surface. A live globe
/// tracking vessels (oil tankers in ember), seismic events, and the world oil
/// chokepoints, beside an intel panel of chokepoint congestion + the physical-alpha
/// signal feed (the alpha Bloomberg cannot natively produce).
public struct GeoIntelligenceView: View {
    let store: GeoIntelligenceStore
    let rates: MacroRatesStore?

    public init(store: GeoIntelligenceStore, rates: MacroRatesStore? = nil) {
        self.store = store
        self.rates = rates
    }

    public var body: some View {
        HStack(spacing: 0) {
            globe
            Divider().overlay(CortexDesign.border)
            panel.frame(width: 330)
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: Globe

    private var globe: some View {
        ZStack(alignment: .topLeading) {
            GeoGlobeWebView(payloadJSON: store.globePayloadJSON())
            hud.padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GEO-INTELLIGENCE")
                .font(CortexDesign.sectionFont).tracking(2)
                .foregroundStyle(CortexDesign.accentPrimary)
            HStack(spacing: 14) {
                kpi("VESSELS", "\(store.vessels.count)", CortexDesign.neutral)
                kpi("TANKERS", "\(store.tankerCount)", CortexDesign.warning)
                kpi("IN CHOKEPOINT", "\(store.inChokepointCount)", CortexDesign.accentPrimary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
            .fill(CortexDesign.bgDeepest.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
            .strokeBorder(CortexDesign.border, lineWidth: 1))
    }

    private func kpi(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(CortexDesign.badgeFont).foregroundStyle(CortexDesign.neutral)
            Text(value).font(CortexDesign.kpiFont).foregroundStyle(color)
        }
    }

    // MARK: Intel panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CortexDesign.sectionSpacing) {
                if let rates { ratesCard(rates) }
                floatingStorageCard
                congestionSection
                alphaSection
                Spacer(minLength: 8)
            }
            .padding(14)
        }
        .background(CortexDesign.bgDeepest)
    }

    private var floatingStorageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FLOATING STORAGE INDEX").font(CortexDesign.sectionFont)
                .foregroundStyle(CortexDesign.neutral)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.0f", store.floatingStorageScore))
                    .font(CortexDesign.kpiFont)
                    .foregroundStyle(store.floatingStorageScore >= 50 ? CortexDesign.loss : CortexDesign.neutral)
                Text(store.floatingStorageScore >= 50 ? "bearish crude" : "neutral")
                    .font(CortexDesign.badgeFont).foregroundStyle(CortexDesign.neutral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CortexDesign.cardPadding)
        .background(CortexDesign.cardBackground())
    }

    private var congestionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHOKEPOINT CONGESTION").font(CortexDesign.sectionFont)
                .foregroundStyle(CortexDesign.neutral)
            if store.congestion.isEmpty {
                Text("No congestion detected").font(CortexDesign.labelFont)
                    .foregroundStyle(CortexDesign.neutral)
            } else {
                ForEach(store.congestion) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).font(CortexDesign.dataFont).foregroundStyle(Color(white: 0.92))
                            Text("\(c.vesselCount) vessels · \(c.tankerCount) tankers · \(String(format: "%.1f", c.avgSpeedKnots))kn")
                                .font(CortexDesign.badgeFont).foregroundStyle(CortexDesign.neutral)
                        }
                        Spacer()
                        Text(String(format: "%.0f", c.congestionScore))
                            .font(CortexDesign.dataFont)
                            .foregroundStyle(c.congestionScore >= 50 ? CortexDesign.warning : CortexDesign.neutral)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CortexDesign.cardPadding)
        .background(CortexDesign.cardBackground())
    }

    private var alphaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PHYSICAL ALPHA").font(CortexDesign.sectionFont)
                .foregroundStyle(CortexDesign.neutral)
            if store.alpha.isEmpty {
                Text("Awaiting maritime / seismic signals…").font(CortexDesign.labelFont)
                    .foregroundStyle(CortexDesign.neutral)
            } else {
                ForEach(store.alpha) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(a.kind.replacingOccurrences(of: "_", with: " ").uppercased())
                                .font(CortexDesign.badgeFont).foregroundStyle(CortexDesign.accentPrimary)
                            Spacer()
                            Text(a.detail).font(CortexDesign.badgeFont)
                                .foregroundStyle(CortexDesign.neutral)
                        }
                        HStack(spacing: 6) {
                            ForEach(a.tickers, id: \.symbol) { t in
                                Text("\(t.symbol) \(t.direction.uppercased())")
                                    .font(CortexDesign.badgeFont)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                                        .fill((t.direction == "short" ? CortexDesign.loss : CortexDesign.profit).opacity(0.18)))
                                    .foregroundStyle(t.direction == "short" ? CortexDesign.loss : CortexDesign.profit)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    Divider().overlay(CortexDesign.border)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CortexDesign.cardPadding)
        .background(CortexDesign.cardBackground())
    }

    private func ratesCard(_ r: MacroRatesStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("U.S. TREASURY RATES").font(CortexDesign.sectionFont)
                    .foregroundStyle(CortexDesign.neutral)
                Spacer()
                if let s = r.spreadBps {
                    Text(r.inverted ? "INVERTED \(Int(s))bp" : "\(Int(s))bp")
                        .font(CortexDesign.badgeFont)
                        .foregroundStyle(r.inverted ? CortexDesign.loss : CortexDesign.neutral)
                }
            }
            if r.rates.isEmpty {
                Text("Awaiting rates…").font(CortexDesign.labelFont)
                    .foregroundStyle(CortexDesign.neutral)
            } else {
                ForEach(r.rates, id: \.name) { row in
                    HStack {
                        Text(row.name).font(CortexDesign.dataFont).foregroundStyle(Color(white: 0.85))
                        Spacer()
                        Text(String(format: "%.2f%%", row.pct)).font(CortexDesign.dataFont)
                            .foregroundStyle(CortexDesign.accentPrimary)
                    }
                }
                if !r.date.isEmpty {
                    Text(r.date).font(CortexDesign.badgeFont).foregroundStyle(CortexDesign.neutral)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CortexDesign.cardPadding)
        .background(CortexDesign.cardBackground())
    }
}
