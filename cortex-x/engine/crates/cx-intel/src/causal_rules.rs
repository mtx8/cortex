//! The MERIDIAN rulebook: hand-written Dalio-style transmission chains.
//! A rule fires when its theme's 24h article intensity z-scores above
//! threshold; the chain then names the mechanism and the pressured assets.
//! Curated and labeled as such — no fake precision.
//!
//! Themes match `meridian::THEMES` ids. Asset targets prefer tickers from
//! the default REGIMES universe; non-universe names are class labels
//! ("crude oil", "defense sector (RTX/LMT)") so the UI never implies a
//! tradeable signal that the engine does not carry.

/// One static rule: theme bucket -> chain title, mechanism steps, and
/// (target, direction, note) asset pressures.
pub struct CausalRule {
    pub rule_id: &'static str,
    pub theme: &'static str,
    pub title: &'static str,
    pub steps: &'static [&'static str],
    /// (target ticker-or-class, +1 up / -1 down, note)
    pub assets: &'static [(&'static str, i32, &'static str)],
}

/// Fire threshold: 24h article-count z-score vs the 30-day baseline.
pub const FIRE_Z: f64 = 1.5;

/// The full rulebook (28 rules across the eight MERIDIAN themes).
pub fn rules() -> &'static [CausalRule] {
    RULES
}

static RULES: &[CausalRule] = &[
    // ---- armed conflict -------------------------------------------------
    CausalRule {
        rule_id: "AC-01",
        theme: "armed_conflict",
        title: "Conflict escalation -> defense and energy bid",
        steps: &[
            "military escalation raises expected defense procurement",
            "supply-route risk adds a security premium to crude",
            "risk premium compresses broad equity multiples",
        ],
        assets: &[
            ("defense sector (RTX/LMT/NOC)", 1, "procurement expectations rise"),
            ("XOM", 1, "crude security premium lifts producer cash flows"),
            ("CVX", 1, "same crude-premium channel"),
            ("SPY", -1, "broad risk premium expands"),
            ("airlines (DAL/UAL)", -1, "jet fuel costs and route closures"),
        ],
    },
    CausalRule {
        rule_id: "AC-02",
        theme: "armed_conflict",
        title: "Shipping-lane disruption -> freight and import costs",
        steps: &[
            "strait or canal threat forces rerouting and war-risk insurance",
            "effective freight capacity shrinks, rates rise",
            "importers absorb higher landed costs or raise prices",
        ],
        assets: &[
            ("tankers/shipping (FRO/ZIM)", 1, "longer routes at higher rates"),
            ("crude oil", 1, "transit risk premium"),
            ("WMT", -1, "imported-goods margin squeeze"),
            ("HD", -1, "freight-heavy import mix"),
        ],
    },
    CausalRule {
        rule_id: "AC-03",
        theme: "armed_conflict",
        title: "Conflict shock -> flight to quality",
        steps: &[
            "geopolitical shock lifts demand for safe assets",
            "treasuries and gold catch the hedge bid",
            "high-multiple and small-cap equities de-rate first",
        ],
        assets: &[
            ("US treasuries", 1, "classic safe-haven flow"),
            ("gold", 1, "geopolitical hedge demand"),
            ("QQQ", -1, "long-duration multiples compress"),
            ("IWM", -1, "risk appetite withdraws from small caps"),
        ],
    },
    CausalRule {
        rule_id: "AC-04",
        theme: "armed_conflict",
        title: "Sustained conflict -> defense budget cycle",
        steps: &[
            "prolonged conflict hardens political support for defense spending",
            "appropriations grow prime-contractor backlogs",
            "engine and aerostructure suppliers ride the same cycle",
        ],
        assets: &[
            ("defense primes (RTX/LMT/GD)", 1, "multi-year backlog growth"),
            ("GE", 1, "defense/aerospace engine demand"),
            ("BA", 1, "defense unit orders; civil exposure dilutes"),
        ],
    },
    // ---- sanctions / trade war ------------------------------------------
    CausalRule {
        rule_id: "ST-01",
        theme: "sanctions_trade",
        title: "Tariff escalation -> import-cost push",
        steps: &[
            "new tariffs raise landed costs on imported goods",
            "retailers either eat margin or push prices and lose volume",
            "reshoring narrative favors domestically weighted names",
        ],
        assets: &[
            ("WMT", -1, "import-heavy assortment, price-sensitive customer"),
            ("COST", -1, "same import-cost channel"),
            ("HD", -1, "imported hardlines and materials"),
            ("IWM", 1, "relative beneficiary: domestic revenue mix"),
        ],
    },
    CausalRule {
        rule_id: "ST-02",
        theme: "sanctions_trade",
        title: "Export bans -> semiconductor revenue risk",
        steps: &[
            "export-license denials cut off China datacenter/handset demand",
            "affected vendors guide revenue down",
            "sector multiples de-rate on policy uncertainty",
        ],
        assets: &[
            ("NVDA", -1, "China datacenter accelerators restricted"),
            ("AMD", -1, "same accelerator restrictions"),
            ("QCOM", -1, "China handset exposure"),
            ("AVGO", -1, "China networking/OEM exposure"),
        ],
    },
    CausalRule {
        rule_id: "ST-03",
        theme: "sanctions_trade",
        title: "Sanctions on a commodity exporter -> supply restriction",
        steps: &[
            "sanctions pull sanctioned barrels/tonnage off open markets",
            "buyers compete for the remaining compliant supply",
            "energy producers gain; fuel-intensive sectors get squeezed",
        ],
        assets: &[
            ("crude oil", 1, "restricted supply, sticky demand"),
            ("XOM", 1, "price-taker upside on compliant supply"),
            ("CVX", 1, "same producer channel"),
            ("airlines (DAL/UAL/LUV)", -1, "fuel is the largest variable cost"),
        ],
    },
    CausalRule {
        rule_id: "ST-04",
        theme: "sanctions_trade",
        title: "Retaliation risk -> US brands with China exposure",
        steps: &[
            "counter-sanctions target market access of US brands",
            "regulatory and consumer-boycott pressure builds in China",
            "China-revenue-heavy names carry a policy discount",
        ],
        assets: &[
            ("AAPL", -1, "China revenue and assembly concentration"),
            ("TSLA", -1, "Shanghai output and China demand exposure"),
            ("QCOM", -1, "licensing revenue tied to Chinese OEMs"),
        ],
    },
    // ---- energy / OPEC ---------------------------------------------------
    CausalRule {
        rule_id: "EN-01",
        theme: "energy_opec",
        title: "Supply cut or outage -> crude rally",
        steps: &[
            "OPEC+ cut or unplanned outage removes barrels",
            "inventories draw and spot prices rise",
            "producer cash flows swell while fuel consumers get squeezed",
        ],
        assets: &[
            ("crude oil", 1, "supply removed against inelastic demand"),
            ("XOM", 1, "direct price beneficiary"),
            ("CVX", 1, "direct price beneficiary"),
            ("airlines (DAL/UAL/LUV)", -1, "jet fuel cost shock"),
        ],
    },
    CausalRule {
        rule_id: "EN-02",
        theme: "energy_opec",
        title: "Energy-led inflation impulse -> duration de-rate",
        steps: &[
            "energy prices push headline CPI higher",
            "rate-cut expectations get pushed out",
            "long-duration equities and bonds reprice lower",
        ],
        assets: &[
            ("QQQ", -1, "discount-rate sensitivity of long-duration growth"),
            ("US treasuries", -1, "higher-for-longer repricing"),
            ("XOM", 1, "the inflation source is its revenue line"),
        ],
    },
    CausalRule {
        rule_id: "EN-03",
        theme: "energy_opec",
        title: "Natural-gas shock -> transatlantic energy arbitrage",
        steps: &[
            "pipeline or LNG disruption spikes European gas prices",
            "energy-intensive European industry curtails output",
            "US LNG exporters capture the widened arbitrage",
        ],
        assets: &[
            ("US LNG exporters (LNG/EQT)", 1, "arbitrage window widens"),
            ("European industrials", -1, "energy input costs surge"),
            ("EUR (vs USD)", -1, "terms-of-trade deterioration"),
        ],
    },
    // ---- central banks / inflation ---------------------------------------
    CausalRule {
        rule_id: "CB-01",
        theme: "central_banks",
        title: "Hawkish surprise -> long-duration de-rate",
        steps: &[
            "hot inflation prints or hawkish guidance lift the expected path",
            "discount rates rise across the curve",
            "high-multiple growth compresses; bank margins get partial relief",
        ],
        assets: &[
            ("QQQ", -1, "duration-heavy index"),
            ("NVDA", -1, "high-multiple growth, rate-sensitive"),
            ("JPM", 1, "net interest margin tailwind"),
            ("BAC", 1, "same NIM channel"),
        ],
    },
    CausalRule {
        rule_id: "CB-02",
        theme: "central_banks",
        title: "Dovish pivot -> risk-on rotation",
        steps: &[
            "cuts get signaled; real yields fall",
            "equity multiples expand and refinancing pressure eases",
            "small caps and non-yielding hedges outperform",
        ],
        assets: &[
            ("QQQ", 1, "multiple expansion"),
            ("IWM", 1, "refinancing relief for leveraged small caps"),
            ("gold", 1, "lower real yields cut the carry cost"),
            ("USD", -1, "rate differential narrows"),
        ],
    },
    CausalRule {
        rule_id: "CB-03",
        theme: "central_banks",
        title: "Sticky inflation -> pricing-power test in staples",
        steps: &[
            "input and wage costs stay elevated",
            "staples' price increases start losing volume",
            "consumers trade down toward discounters",
        ],
        assets: &[
            ("PG", -1, "pass-through fatigue, volume risk"),
            ("KO", -1, "same elasticity pressure"),
            ("PEP", -1, "snacks/beverage input costs"),
            ("WMT", 1, "trade-down share gains"),
            ("COST", 1, "value channel gains share"),
        ],
    },
    CausalRule {
        rule_id: "CB-04",
        theme: "central_banks",
        title: "Deepening inversion -> credit tightening",
        steps: &[
            "short rates above long rates squeeze maturity transformation",
            "lending standards tighten and credit growth slows",
            "capex-driven cyclicals feel the slowdown first",
        ],
        assets: &[
            ("regional banks (KRE)", -1, "funding-cost squeeze is most acute"),
            ("BAC", -1, "deposit beta pressure on margins"),
            ("CAT", -1, "credit-financed equipment demand slows"),
        ],
    },
    // ---- sovereign debt ---------------------------------------------------
    CausalRule {
        rule_id: "SD-01",
        theme: "sovereign_debt",
        title: "Debt-crisis flare -> flight to the dollar",
        steps: &[
            "sovereign stress triggers capital flight",
            "dollar funding demand spikes",
            "EM assets sell off while treasuries catch the bid",
        ],
        assets: &[
            ("US treasuries", 1, "reserve-asset bid"),
            ("USD", 1, "funding-currency squeeze"),
            ("EM equities (EEM)", -1, "capital flight epicenter"),
            ("EM sovereign debt", -1, "spread blowout"),
        ],
    },
    CausalRule {
        rule_id: "SD-02",
        theme: "sovereign_debt",
        title: "US fiscal scare -> term-premium repricing",
        steps: &[
            "deficit or downgrade headlines revive supply concerns",
            "term premium pushes long yields higher",
            "equity valuations and long bonds reprice; gold hedges the regime",
        ],
        assets: &[
            ("US long treasuries (TLT)", -1, "duration bears the repricing"),
            ("SPY", -1, "higher discount rate on the index"),
            ("gold", 1, "fiscal-credibility hedge"),
        ],
    },
    CausalRule {
        rule_id: "SD-03",
        theme: "sovereign_debt",
        title: "IMF program / austerity -> fiscal drag",
        steps: &[
            "program conditionality forces spending cuts and tax rises",
            "domestic demand contracts in the program country",
            "creditors with local exposure mark down loan books",
        ],
        assets: &[
            ("global banks with EM books (C/HSBC)", -1, "loan-book markdowns"),
            ("program-country sovereign bonds", 1, "relief rally on agreement"),
            ("EM equities (EEM)", -1, "regional demand contraction"),
        ],
    },
    // ---- elections / instability ------------------------------------------
    CausalRule {
        rule_id: "EL-01",
        theme: "elections_instability",
        title: "Political instability -> policy risk premium",
        steps: &[
            "contested transition or coup raises policy uncertainty",
            "businesses defer investment and hedging demand rises",
            "country risk premium widens across local assets",
        ],
        assets: &[
            ("volatility (VIX futures)", 1, "hedging demand"),
            ("SPY", -1, "risk premium expansion spills over"),
            ("affected-country equities", -1, "direct policy uncertainty"),
        ],
    },
    CausalRule {
        rule_id: "EL-02",
        theme: "elections_instability",
        title: "Unrest in a commodity producer -> supply risk",
        steps: &[
            "strikes or unrest threaten mines, fields and ports",
            "supply risk premia build in the affected commodities",
            "safe-haven demand firms alongside",
        ],
        assets: &[
            ("copper", 1, "mine-disruption premium"),
            ("crude oil", 1, "field/port disruption premium"),
            ("gold", 1, "instability hedge"),
        ],
    },
    CausalRule {
        rule_id: "EL-03",
        theme: "elections_instability",
        title: "US election cycle -> sector policy repricing",
        steps: &[
            "platforms diverge on drug pricing, tariffs and energy policy",
            "policy-exposed sectors carry headline risk into the vote",
            "cross-sector dispersion rises while the index nets out",
        ],
        assets: &[
            ("UNH", -1, "drug-pricing and reimbursement headline risk"),
            ("LLY", -1, "same pricing-policy channel"),
            ("volatility (VIX futures)", 1, "event-risk hedging into the date"),
        ],
    },
    // ---- tech export controls ----------------------------------------------
    CausalRule {
        rule_id: "TE-01",
        theme: "tech_exports",
        title: "Chip export controls tighten -> vendor revenue cut",
        steps: &[
            "new license rules block advanced-chip sales to China",
            "affected vendors lose a top-3 end market",
            "Chinese domestic substitution accelerates behind the wall",
        ],
        assets: &[
            ("NVDA", -1, "restricted accelerator SKUs"),
            ("AMD", -1, "same restriction set"),
            ("AVGO", -1, "networking silicon exposure"),
            ("Chinese domestic semis (SMIC class)", 1, "forced substitution demand"),
        ],
    },
    CausalRule {
        rule_id: "TE-02",
        theme: "tech_exports",
        title: "Semicap equipment bans -> China fab buildout stalls",
        steps: &[
            "tool export bans halt advanced-node expansion in China",
            "equipment makers lose booked and pipeline China revenue",
            "geopolitical overhang widens across the foundry chain",
        ],
        assets: &[
            ("semicap equipment (AMAT/LRCX/ASML)", -1, "China order book at risk"),
            ("TSM", -1, "cross-strait risk premium repricing"),
        ],
    },
    CausalRule {
        rule_id: "TE-03",
        theme: "tech_exports",
        title: "Decoupling -> reshoring capex wave",
        steps: &[
            "controls broaden and supply-chain security becomes policy",
            "onshore fab and assembly construction accelerates",
            "heavy equipment and automation suppliers take the capex",
        ],
        assets: &[
            ("CAT", 1, "site development and heavy equipment"),
            ("industrial automation (ROK/ETN)", 1, "fab electrification/automation"),
            ("fab construction/engineering", 1, "multi-year buildout backlog"),
        ],
    },
    // ---- natural disasters ---------------------------------------------------
    CausalRule {
        rule_id: "ND-01",
        theme: "natural_disasters",
        title: "Major landfall -> insured-loss and rebuild cycle",
        steps: &[
            "hurricane or quake generates large insured losses",
            "insurers take the hit, then reinsurance pricing hardens",
            "rebuild demand pulls forward building-materials sales",
        ],
        assets: &[
            ("P&C insurers (ALL/TRV)", -1, "near-term loss recognition"),
            ("reinsurance (RNR/EG)", 1, "pricing cycle hardens next renewal"),
            ("HD", 1, "repair and rebuild demand"),
            ("building materials/lumber", 1, "rebuild pull-forward"),
        ],
    },
    CausalRule {
        rule_id: "ND-02",
        theme: "natural_disasters",
        title: "Drought / crop failure -> food-cost push",
        steps: &[
            "yield losses tighten grain and softs balances",
            "agricultural input prices rise into the next planting cycle",
            "packaged-food margins lag the input shock",
        ],
        assets: &[
            ("grains (wheat/corn)", 1, "tightened supply balance"),
            ("fertilizer (MOS/NTR)", 1, "replant and yield-recovery demand"),
            ("PEP", -1, "snack/beverage input cost lag"),
            ("packaged food (KHC/GIS)", -1, "same input-cost squeeze"),
        ],
    },
    CausalRule {
        rule_id: "ND-03",
        theme: "natural_disasters",
        title: "Gulf storm -> energy infrastructure shut-ins",
        steps: &[
            "platforms and refineries shut in ahead of landfall",
            "refined-product supply tightens faster than crude",
            "crack spreads and pump prices move first",
        ],
        assets: &[
            ("refiners (VLO/MPC)", 1, "crack-spread expansion"),
            ("XOM", 1, "integrated upside on products"),
            ("gasoline/crack spreads", 1, "product-led tightening"),
            ("airlines (DAL/UAL)", -1, "jet fuel follows the products complex"),
        ],
    },
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    const THEME_IDS: &[&str] = &[
        "armed_conflict",
        "sanctions_trade",
        "energy_opec",
        "central_banks",
        "sovereign_debt",
        "elections_instability",
        "tech_exports",
        "natural_disasters",
    ];

    #[test]
    fn rulebook_is_consistent() {
        let all = rules();
        assert!(all.len() >= 25, "rulebook has {} rules", all.len());
        let mut ids = HashSet::new();
        for rule in all {
            assert!(ids.insert(rule.rule_id), "duplicate rule_id {}", rule.rule_id);
            assert!(
                THEME_IDS.contains(&rule.theme),
                "{}: unknown theme {}",
                rule.rule_id,
                rule.theme
            );
            assert!(!rule.title.is_empty());
            assert!(
                (3..=5).contains(&rule.steps.len()),
                "{}: {} steps",
                rule.rule_id,
                rule.steps.len()
            );
            assert!(rule.steps.iter().all(|s| !s.is_empty()));
            assert!(
                (2..=5).contains(&rule.assets.len()),
                "{}: {} assets",
                rule.rule_id,
                rule.assets.len()
            );
            for (target, dir, note) in rule.assets {
                assert!(!target.is_empty());
                assert!(*dir == 1 || *dir == -1, "{}: direction {dir}", rule.rule_id);
                assert!(!note.is_empty());
            }
        }
        // Every theme has at least one rule.
        for theme in THEME_IDS {
            assert!(
                all.iter().any(|r| r.theme == *theme),
                "theme {theme} has no rules"
            );
        }
    }
}
