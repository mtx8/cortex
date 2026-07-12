//! Curated supply-chain graph — the hand-maintained SPLC dataset.
//! Source label: "curated graph (MTX Labs, 2026-07)". Honesty rule: this is
//! research seed data, not a live feed, and it says so in every profile.
//!
//! Curation rules: only well-known, publicly documented relationships;
//! counterparties that are not US-listed carry `symbol: None`; every `via`
//! note says what actually flows across the relation. Grouped by sector.

use cx_core::events::{CompanyProfile, Relation, Segment};

pub const GRAPH_SOURCE: &str = "curated graph (MTX Labs, 2026-07)";

/// Every symbol in the curated set (kept in sync with [`curated`] by test).
#[cfg(test)]
pub(crate) const CURATED_SYMBOLS: &[&str] = &[
    // Semiconductors & hardware
    "NVDA", "AMD", "INTC", "QCOM", "AVGO", "TXN", "MU", "TSM", "ASML", "SMCI", "DELL", "AAPL",
    // Software, internet & platforms
    "MSFT", "GOOGL", "META", "AMZN", "ORCL", "CRM", "ADBE", "NFLX", "SNOW", "PLTR", "SHOP",
    "UBER", "ABNB",
    // Financials & payments
    "JPM", "BAC", "GS", "MS", "V", "MA", "PYPL", "SQ", "COIN",
    // Consumer, retail & autos
    "WMT", "COST", "HD", "PG", "KO", "PEP", "NKE", "SBUX", "DIS", "F", "GM", "TSLA",
    // Health care
    "UNH", "LLY", "ABBV", "MRK", "PFE",
    // Energy, industrials & defense
    "XOM", "CVX", "CAT", "BA", "GE", "HON", "LMT",
    // Communications
    "VZ",
    // Index funds
    "SPY", "QQQ",
];

type Seg<'a> = (&'a str, &'a str);
type Rel<'a> = (Option<&'a str>, &'a str, &'a str);

fn rels(xs: &[Rel]) -> Vec<Relation> {
    xs.iter()
        .map(|(sym, name, via)| Relation {
            symbol: sym.map(str::to_string),
            name: (*name).to_string(),
            via: (*via).to_string(),
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn p(
    symbol: &str,
    name: &str,
    sector: &str,
    industry: &str,
    country: &str,
    description: &str,
    segments: &[Seg],
    suppliers: &[Rel],
    customers: &[Rel],
    competitors: &[&str],
) -> CompanyProfile {
    CompanyProfile {
        symbol: symbol.to_string(),
        name: name.to_string(),
        sector: sector.to_string(),
        industry: industry.to_string(),
        country: country.to_string(),
        description: description.to_string(),
        segments: segments
            .iter()
            .map(|(n, note)| Segment { name: (*n).to_string(), note: (*note).to_string() })
            .collect(),
        suppliers: rels(suppliers),
        customers: rels(customers),
        competitors: competitors.iter().map(|c| (*c).to_string()).collect(),
        fundamentals: None,
        graph_source: GRAPH_SOURCE.to_string(),
        fundamentals_source: "unavailable".to_string(),
        ts_ms: 0,
    }
}

/// Curated profile (graph half only — fundamentals arrive from EDGAR).
/// Returns None for symbols outside the curated set.
pub fn curated(symbol: &str) -> Option<CompanyProfile> {
    let c = match symbol {
        // ── Semiconductors & hardware ────────────────────────────────────
        "NVDA" => p(
            "NVDA", "NVIDIA Corporation", "Technology", "Semiconductors", "United States",
            "Designs GPUs and full-stack accelerated computing platforms; the dominant \
             supplier of AI training and inference silicon.",
            &[
                ("Data Center", "Hopper/Blackwell AI accelerators and DGX/HGX systems"),
                ("Gaming", "GeForce RTX GPUs"),
                ("Professional Visualization", "RTX workstation graphics, Omniverse"),
                ("Automotive", "DRIVE autonomous-vehicle compute"),
                ("Networking", "Mellanox InfiniBand/Ethernet for AI clusters"),
            ],
            &[
                (Some("TSM"), "TSMC", "leading-edge wafer fabrication and CoWoS packaging"),
                (None, "SK Hynix", "HBM memory"),
                (Some("MU"), "Micron", "HBM3E and graphics memory"),
                (None, "Samsung Electronics", "memory and secondary fabrication"),
                (None, "Foxconn (Hon Hai)", "board and system assembly"),
                (None, "Wistron", "server board assembly"),
            ],
            &[
                (Some("MSFT"), "Microsoft", "hyperscale AI capex (Azure)"),
                (Some("META"), "Meta", "AI training clusters"),
                (Some("GOOGL"), "Alphabet", "Google Cloud GPU fleets"),
                (Some("AMZN"), "Amazon", "AWS GPU instances"),
                (Some("ORCL"), "Oracle", "OCI GPU superclusters"),
                (Some("TSLA"), "Tesla", "AI training infrastructure"),
                (Some("DELL"), "Dell", "AI-factory server builds"),
                (Some("SMCI"), "Super Micro", "GPU server systems"),
            ],
            &["AMD", "INTC", "AVGO", "GOOGL"],
        ),
        "AMD" => p(
            "AMD", "Advanced Micro Devices", "Technology", "Semiconductors", "United States",
            "Fabless designer of x86 CPUs, GPUs and adaptive SoCs; the main merchant \
             challenger to NVIDIA in AI accelerators and to Intel in server CPUs.",
            &[
                ("Data Center", "EPYC server CPUs, Instinct MI-series AI accelerators"),
                ("Client", "Ryzen PC processors"),
                ("Gaming", "Radeon GPUs and semi-custom console SoCs"),
                ("Embedded", "Xilinx FPGAs and adaptive SoCs"),
            ],
            &[
                (Some("TSM"), "TSMC", "CPU/GPU wafer fabrication"),
                (Some("GFS"), "GlobalFoundries", "I/O dies and mature-node wafers"),
                (None, "SK Hynix", "HBM for Instinct accelerators"),
                (None, "ASE Technology", "packaging and test"),
            ],
            &[
                (Some("MSFT"), "Microsoft", "Azure EPYC/MI instances and Xbox semi-custom SoCs"),
                (Some("SONY"), "Sony", "PlayStation semi-custom SoCs"),
                (Some("META"), "Meta", "MI-series AI inference fleet"),
                (Some("ORCL"), "Oracle", "OCI EPYC and Instinct capacity"),
                (Some("DELL"), "Dell", "commercial PCs and servers"),
            ],
            &["NVDA", "INTC", "QCOM"],
        ),
        "INTC" => p(
            "INTC", "Intel Corporation", "Technology", "Semiconductors", "United States",
            "Integrated device manufacturer of PC and server CPUs, rebuilding process \
             leadership and opening its fabs to external foundry customers.",
            &[
                ("Client Computing", "Core PC processors"),
                ("Data Center & AI", "Xeon server CPUs, Gaudi accelerators"),
                ("Intel Foundry", "18A-generation external foundry push"),
                ("Altera & Mobileye", "FPGAs and ADAS subsidiaries"),
            ],
            &[
                (Some("ASML"), "ASML", "EUV and High-NA lithography systems"),
                (Some("AMAT"), "Applied Materials", "deposition and process equipment"),
                (Some("LRCX"), "Lam Research", "etch equipment"),
                (Some("TSM"), "TSMC", "outsourced compute tiles for client SoCs"),
            ],
            &[
                (Some("DELL"), "Dell", "PC and server CPUs"),
                (Some("HPQ"), "HP Inc.", "PC CPUs"),
                (None, "Lenovo", "PC and server CPUs"),
                (Some("MSFT"), "Microsoft", "Surface silicon and announced 18A foundry work"),
                (Some("AMZN"), "Amazon", "custom Xeon and foundry partnership"),
            ],
            &["AMD", "NVDA", "TSM", "QCOM"],
        ),
        "QCOM" => p(
            "QCOM", "Qualcomm", "Technology", "Semiconductors", "United States",
            "Fabless leader in smartphone SoCs and cellular modems, expanding into \
             automotive cockpits and Windows-on-Arm PCs; also earns patent royalties.",
            &[
                ("Handsets", "Snapdragon SoCs and modems"),
                ("Automotive", "Snapdragon Digital Chassis"),
                ("IoT & PC", "Snapdragon X for Windows PCs, embedded"),
                ("Licensing (QTL)", "cellular patent royalties"),
            ],
            &[
                (Some("TSM"), "TSMC", "SoC fabrication"),
                (None, "Samsung Foundry", "secondary SoC fabrication"),
                (None, "ASE Technology", "packaging and test"),
            ],
            &[
                (Some("AAPL"), "Apple", "iPhone 5G modems"),
                (None, "Samsung Electronics", "Galaxy flagship Snapdragon SoCs"),
                (None, "Xiaomi and Android OEMs", "smartphone SoCs"),
                (Some("GM"), "General Motors", "Snapdragon digital cockpit"),
            ],
            &["AVGO", "INTC", "AMD"],
        ),
        "AVGO" => p(
            "AVGO", "Broadcom", "Technology", "Semiconductors & Infrastructure Software",
            "United States",
            "Networking silicon, custom AI accelerators and RF chips, paired with a \
             large infrastructure-software arm (VMware).",
            &[
                ("AI Networking & Custom Silicon", "Tomahawk/Jericho switch ASICs, custom XPUs"),
                ("Wireless", "RF front-end and connectivity for smartphones"),
                ("Server Storage & Broadband", "controllers and access silicon"),
                ("Infrastructure Software", "VMware, mainframe and security software"),
            ],
            &[
                (Some("TSM"), "TSMC", "wafer fabrication"),
                (None, "ASE Technology", "packaging and test"),
                (None, "Ibiden / Unimicron", "ABF package substrates"),
            ],
            &[
                (Some("AAPL"), "Apple", "RF and wireless content in iPhone"),
                (Some("GOOGL"), "Alphabet", "TPU custom-silicon co-design"),
                (Some("META"), "Meta", "MTIA custom accelerators and networking"),
                (Some("MSFT"), "Microsoft", "data-center networking silicon"),
                (None, "OpenAI", "custom AI accelerator program"),
            ],
            &["NVDA", "AMD", "MRVL", "QCOM"],
        ),
        "TXN" => p(
            "TXN", "Texas Instruments", "Technology", "Semiconductors (Analog)", "United States",
            "The largest analog chipmaker, manufacturing in-house on 300mm wafers for \
             tens of thousands of industrial and automotive customers.",
            &[
                ("Analog", "power management and signal-chain chips"),
                ("Embedded Processing", "microcontrollers and processors"),
                ("Other", "DLP projection, calculators"),
            ],
            &[
                (Some("ASML"), "ASML", "lithography systems for owned fabs"),
                (Some("AMAT"), "Applied Materials", "fab equipment"),
                (None, "Shin-Etsu / SUMCO", "silicon wafers"),
            ],
            &[
                (None, "Industrial OEMs", "factory automation and grid analog content"),
                (Some("F"), "Ford", "automotive analog and embedded chips"),
                (Some("GM"), "General Motors", "automotive analog and embedded chips"),
                (Some("AAPL"), "Apple", "analog content in consumer devices"),
            ],
            &["ADI", "NXPI", "ON", "MCHP"],
        ),
        "MU" => p(
            "MU", "Micron Technology", "Technology", "Semiconductors (Memory)", "United States",
            "The only US-based DRAM/NAND maker; a top-three HBM supplier riding AI \
             data-center memory demand.",
            &[
                ("DRAM", "server, PC and mobile memory"),
                ("NAND & SSDs", "storage for data center and client"),
                ("HBM", "high-bandwidth memory for AI accelerators"),
            ],
            &[
                (Some("ASML"), "ASML", "lithography"),
                (Some("AMAT"), "Applied Materials", "deposition/etch equipment"),
                (Some("LRCX"), "Lam Research", "etch equipment"),
                (Some("KLAC"), "KLA", "process control and metrology"),
            ],
            &[
                (Some("NVDA"), "NVIDIA", "HBM3E for Blackwell platforms"),
                (Some("AAPL"), "Apple", "LPDDR mobile memory"),
                (Some("DELL"), "Dell", "server and PC memory"),
                (Some("SMCI"), "Super Micro", "AI server memory"),
                (None, "Smartphone OEMs", "LPDDR and NAND"),
            ],
            &["SNDK", "WDC", "STX"],
        ),
        "TSM" => p(
            "TSM", "Taiwan Semiconductor Manufacturing", "Technology",
            "Semiconductor Foundry", "Taiwan",
            "The world's dominant contract chipmaker: nearly all leading-edge fabless \
             silicon — Apple, NVIDIA, AMD — is fabricated by TSMC.",
            &[
                ("Advanced Logic", "N3/N2 leading-edge nodes"),
                ("Advanced Packaging", "CoWoS/SoIC for AI accelerators"),
                ("Specialty", "mature nodes, RF, image sensors"),
            ],
            &[
                (Some("ASML"), "ASML", "EUV/High-NA lithography — sole source"),
                (Some("AMAT"), "Applied Materials", "deposition and implant equipment"),
                (Some("LRCX"), "Lam Research", "etch equipment"),
                (Some("KLAC"), "KLA", "metrology and inspection"),
                (None, "Shin-Etsu / SUMCO", "silicon wafers"),
            ],
            &[
                (Some("AAPL"), "Apple", "A- and M-series SoC fabrication"),
                (Some("NVDA"), "NVIDIA", "AI GPU fabrication and CoWoS"),
                (Some("AMD"), "AMD", "CPU/GPU fabrication"),
                (Some("QCOM"), "Qualcomm", "Snapdragon fabrication"),
                (Some("AVGO"), "Broadcom", "networking and custom-AI silicon"),
                (Some("INTC"), "Intel", "outsourced compute tiles"),
            ],
            &["INTC", "GFS", "UMC"],
        ),
        "ASML" => p(
            "ASML", "ASML Holding", "Technology", "Semiconductor Equipment", "Netherlands",
            "Monopoly supplier of EUV lithography — the machines every leading-edge \
             fab requires; also sells DUV and metrology with a large service base.",
            &[
                ("EUV", "extreme-ultraviolet lithography systems"),
                ("High-NA EUV", "next-generation 0.55-NA systems"),
                ("DUV", "immersion and dry lithography"),
                ("Installed Base", "service and upgrades"),
            ],
            &[
                (None, "Carl Zeiss SMT", "EUV optics — sole source"),
                (None, "TRUMPF", "EUV drive lasers"),
                (None, "VDL", "modules and assembly"),
            ],
            &[
                (Some("TSM"), "TSMC", "EUV/High-NA fleet"),
                (Some("INTC"), "Intel", "first High-NA systems"),
                (None, "Samsung Electronics", "EUV systems"),
                (Some("MU"), "Micron", "lithography for memory fabs"),
                (None, "SK Hynix", "lithography for memory fabs"),
            ],
            &["AMAT", "LRCX", "KLAC"],
        ),
        "SMCI" => p(
            "SMCI", "Super Micro Computer", "Technology", "Servers & AI Systems",
            "United States",
            "Builds AI/GPU servers and rack-scale liquid-cooled systems on short \
             design cycles; a primary channel for NVIDIA platforms.",
            &[
                ("AI/GPU Servers", "NVIDIA HGX/GB200 rack systems"),
                ("Rack-Scale & Liquid Cooling", "direct-liquid-cooled data-center racks"),
                ("Storage & Edge", "storage servers, edge/telco systems"),
            ],
            &[
                (Some("NVDA"), "NVIDIA", "GPUs and accelerator boards"),
                (Some("AMD"), "AMD", "EPYC CPUs and Instinct accelerators"),
                (Some("INTC"), "Intel", "Xeon CPUs"),
                (Some("MU"), "Micron", "memory and SSDs"),
            ],
            &[
                (Some("CRWV"), "CoreWeave", "AI-cloud GPU fleets"),
                (None, "xAI", "Colossus supercluster servers"),
                (None, "AI cloud operators", "neocloud data-center buildouts"),
            ],
            &["DELL", "HPE"],
        ),
        "DELL" => p(
            "DELL", "Dell Technologies", "Technology", "IT Hardware", "United States",
            "The largest enterprise server and commercial PC vendor; AI-factory server \
             backlog has made it a core NVIDIA channel.",
            &[
                ("Infrastructure Solutions", "PowerEdge servers, AI factories, storage"),
                ("Client Solutions", "commercial PCs and workstations"),
                ("Dell Financial Services", "financing and leasing"),
            ],
            &[
                (Some("NVDA"), "NVIDIA", "AI GPUs and reference platforms"),
                (Some("INTC"), "Intel", "CPUs"),
                (Some("AMD"), "AMD", "CPUs and accelerators"),
                (Some("MU"), "Micron", "memory and storage"),
                (None, "Wistron / Compal", "ODM assembly"),
            ],
            &[
                (None, "Enterprises", "IT infrastructure refresh and AI buildouts"),
                (None, "xAI", "AI cluster servers"),
                (Some("CRWV"), "CoreWeave", "GB200 rack-scale servers"),
            ],
            &["HPE", "HPQ", "SMCI", "AAPL"],
        ),
        "AAPL" => p(
            "AAPL", "Apple Inc.", "Technology", "Consumer Electronics", "United States",
            "Designs the iPhone, Mac and a services ecosystem around in-house silicon; \
             operates one of the world's most scrutinized hardware supply chains.",
            &[
                ("iPhone", "flagship smartphone line"),
                ("Mac", "Apple-silicon computers"),
                ("iPad", "tablets"),
                ("Wearables, Home & Accessories", "Watch, AirPods, Vision Pro"),
                ("Services", "App Store, iCloud, Music/TV+, payments"),
            ],
            &[
                (Some("TSM"), "TSMC", "A- and M-series chip fabrication"),
                (None, "Foxconn (Hon Hai)", "iPhone final assembly"),
                (None, "Samsung Electronics", "OLED panels and NAND"),
                (None, "SK Hynix", "DRAM/NAND memory"),
                (Some("AVGO"), "Broadcom", "RF and wireless chips"),
                (Some("QCOM"), "Qualcomm", "5G modems"),
                (Some("GLW"), "Corning", "cover glass (Ceramic Shield)"),
                (None, "LG Display", "OLED panels"),
            ],
            &[
                (None, "Consumers", "direct retail and online"),
                (Some("VZ"), "Verizon", "carrier iPhone distribution"),
                (Some("TMUS"), "T-Mobile", "carrier iPhone distribution"),
                (Some("T"), "AT&T", "carrier iPhone distribution"),
                (Some("BBY"), "Best Buy", "retail channel"),
            ],
            &["MSFT", "GOOGL", "DELL", "HPQ"],
        ),

        // ── Software, internet & platforms ───────────────────────────────
        "MSFT" => p(
            "MSFT", "Microsoft", "Technology", "Software & Cloud", "United States",
            "Enterprise software and the Azure cloud, with the deepest commercial AI \
             position via the Copilot stack and the OpenAI partnership.",
            &[
                ("Productivity & Business", "Office 365, Teams, LinkedIn, Dynamics"),
                ("Intelligent Cloud", "Azure infrastructure and AI services"),
                ("Personal Computing", "Windows, Surface, Xbox, ads"),
                ("AI", "Copilot products and OpenAI partnership"),
            ],
            &[
                (Some("NVDA"), "NVIDIA", "Azure AI GPUs"),
                (Some("AMD"), "AMD", "EPYC CPUs and MI accelerators"),
                (Some("INTC"), "Intel", "Xeon CPUs"),
                (None, "OpenAI", "frontier models behind Copilot"),
                (None, "ODM server makers", "hyperscale rack assembly"),
            ],
            &[
                (None, "Enterprises", "cloud and productivity estates"),
                (None, "OpenAI", "Azure compute commitments"),
                (None, "Consumers", "Windows, Xbox, Game Pass"),
                (None, "Governments", "sovereign cloud and productivity"),
            ],
            &["GOOGL", "AMZN", "AAPL", "ORCL", "CRM"],
        ),
        "GOOGL" => p(
            "GOOGL", "Alphabet", "Communication Services", "Internet & Cloud", "United States",
            "Search and YouTube advertising, Google Cloud, Android and in-house TPU \
             silicon; Gemini anchors its AI stack end to end.",
            &[
                ("Search & Ads", "core advertising franchise"),
                ("YouTube", "ads plus subscriptions"),
                ("Google Cloud", "GCP infrastructure and Workspace"),
                ("Android & Devices", "Play store, Pixel"),
                ("Other Bets", "Waymo autonomous driving"),
            ],
            &[
                (Some("AVGO"), "Broadcom", "TPU custom-silicon co-design"),
                (Some("TSM"), "TSMC", "TPU fabrication"),
                (Some("NVDA"), "NVIDIA", "cloud GPU fleets"),
                (None, "Samsung Electronics", "Pixel components"),
            ],
            &[
                (None, "Advertisers", "search and YouTube ad spend"),
                (None, "Cloud enterprises", "GCP and Workspace"),
                (None, "App developers", "Play distribution and billing"),
            ],
            &["MSFT", "META", "AMZN", "AAPL"],
        ),
        "META" => p(
            "META", "Meta Platforms", "Communication Services", "Social Media",
            "United States",
            "Runs Facebook, Instagram and WhatsApp on an advertising engine, while \
             spending heavily on AI infrastructure and smart glasses.",
            &[
                ("Family of Apps", "Facebook, Instagram, WhatsApp, Threads"),
                ("Advertising", "targeted ads across the app family"),
                ("Reality Labs", "Quest headsets, Ray-Ban smart glasses"),
                ("AI Infrastructure", "Llama models, giga-scale data centers"),
            ],
            &[
                (Some("NVDA"), "NVIDIA", "AI training GPUs"),
                (Some("AMD"), "AMD", "inference accelerators"),
                (Some("AVGO"), "Broadcom", "MTIA custom silicon and networking"),
                (None, "ODM server makers", "OCP rack systems"),
            ],
            &[
                (None, "Advertisers", "targeted ad spend"),
                (None, "Small businesses", "click-to-message and commerce ads"),
                (None, "Developers", "Llama open-model ecosystem"),
            ],
            &["GOOGL", "SNAP", "NFLX"],
        ),
        "AMZN" => p(
            "AMZN", "Amazon.com", "Consumer Discretionary", "E-Commerce & Cloud",
            "United States",
            "The largest online retailer and, through AWS, the largest cloud provider; \
             advertising and logistics round out the flywheel.",
            &[
                ("Retail", "North America and International e-commerce"),
                ("AWS", "cloud infrastructure and AI services"),
                ("Advertising", "sponsored products and streaming ads"),
                ("Subscriptions", "Prime"),
                ("Logistics", "fulfillment and delivery network"),
            ],
            &[
                (None, "Marketplace sellers", "third-party inventory (majority of units)"),
                (Some("PG"), "Procter & Gamble", "consumer staples inventory"),
                (Some("NVDA"), "NVIDIA", "AWS AI GPUs"),
                (Some("TSM"), "TSMC", "Graviton/Trainium in-house chip fabrication"),
                (None, "USPS and carriers", "last-mile capacity"),
            ],
            &[
                (None, "Consumers", "Prime retail demand"),
                (Some("NFLX"), "Netflix", "AWS streaming infrastructure"),
                (Some("ABNB"), "Airbnb", "AWS hosting"),
                (Some("SNOW"), "Snowflake", "AWS-hosted data platform"),
                (None, "Anthropic", "Trainium capacity and cloud partnership"),
            ],
            &["WMT", "MSFT", "GOOGL", "COST"],
        ),
        "ORCL" => p(
            "ORCL", "Oracle", "Technology", "Software & Cloud", "United States",
            "Database and enterprise applications vendor that has become a major AI \
             cloud, building GPU superclusters for frontier-model customers.",
            &[
                ("Cloud Infrastructure", "OCI and GPU superclusters"),
                ("Cloud Applications", "Fusion, NetSuite"),
                ("Database", "Oracle DB, MySQL, autonomous services"),
                ("Industry", "Cerner health systems"),
            ],
            &[
                (Some("NVDA"), "NVIDIA", "GB200 supercluster GPUs"),
                (Some("AMD"), "AMD", "EPYC CPUs and MI accelerators"),
                (None, "Server ODMs", "data-center buildout"),
            ],
            &[
                (None, "OpenAI", "Stargate AI compute"),
                (None, "TikTok / ByteDance", "US cloud hosting"),
                (None, "Enterprises", "ERP and database estates"),
                (Some("UBER"), "Uber", "cloud infrastructure"),
            ],
            &["MSFT", "AMZN", "GOOGL", "SAP", "CRM"],
        ),
        "CRM" => p(
            "CRM", "Salesforce", "Technology", "Enterprise Software", "United States",
            "The leading CRM platform, extending into data and agentic AI with Data \
             Cloud and Agentforce.",
            &[
                ("Sales & Service Cloud", "core CRM seats"),
                ("Marketing & Commerce", "campaign and storefront tools"),
                ("Platform", "Slack, MuleSoft, Tableau"),
                ("Data Cloud & AI", "Agentforce agentic layer"),
            ],
            &[
                (Some("AMZN"), "Amazon", "Hyperforce on AWS"),
                (Some("GOOGL"), "Alphabet", "Google Cloud infrastructure partnership"),
                (None, "Data-center providers", "colocation for legacy pods"),
            ],
            &[
                (None, "Enterprises", "CRM and platform seats"),
                (None, "SMBs", "Starter suites"),
                (None, "Governments", "GovCloud deployments"),
            ],
            &["MSFT", "ORCL", "SAP", "NOW", "ADBE"],
        ),
        "ADBE" => p(
            "ADBE", "Adobe", "Technology", "Software", "United States",
            "Creative and document software standard-bearer, embedding Firefly \
             generative AI across Creative Cloud and Acrobat.",
            &[
                ("Creative Cloud", "Photoshop, Premiere, Express"),
                ("Document Cloud", "Acrobat and e-signatures"),
                ("Experience Cloud", "marketing and analytics"),
                ("Firefly", "generative AI models"),
            ],
            &[
                (Some("AMZN"), "Amazon", "cloud hosting"),
                (Some("MSFT"), "Microsoft", "Azure hosting"),
                (Some("NVDA"), "NVIDIA", "Firefly model training GPUs"),
            ],
            &[
                (None, "Creative professionals", "Creative Cloud subscriptions"),
                (None, "Enterprises", "marketing/analytics stack"),
                (None, "Knowledge workers", "Acrobat and PDF workflows"),
            ],
            &["FIG", "CRM", "MSFT"],
        ),
        "NFLX" => p(
            "NFLX", "Netflix", "Communication Services", "Streaming", "United States",
            "The largest subscription streamer, layering an ads tier, games and live \
             events on top of a global originals engine.",
            &[
                ("Streaming", "subscription video on demand"),
                ("Ads Tier", "advertising-supported plans"),
                ("Games", "mobile and cloud games"),
                ("Live", "sports and event programming"),
            ],
            &[
                (Some("AMZN"), "Amazon", "AWS infrastructure"),
                (Some("SONY"), "Sony", "licensed films and series"),
                (Some("WBD"), "Warner Bros. Discovery", "licensed catalog"),
                (None, "Production studios", "originals production"),
            ],
            &[
                (None, "Subscribers", "300M+ paying households"),
                (None, "Advertisers", "ads-tier inventory"),
                (None, "Telco bundlers", "distribution partnerships"),
            ],
            &["DIS", "AMZN", "WBD", "AAPL"],
        ),
        "SNOW" => p(
            "SNOW", "Snowflake", "Technology", "Data Cloud", "United States",
            "Cloud-neutral data platform for warehousing, sharing and AI workloads, \
             reselling hyperscaler compute under its own consumption model.",
            &[
                ("Data Platform", "warehousing and lakehouse workloads"),
                ("Cortex AI", "LLM functions over governed data"),
                ("Marketplace", "cross-company data sharing"),
                ("Snowpark", "developer and ML workloads"),
            ],
            &[
                (Some("AMZN"), "Amazon", "underlying AWS compute/storage"),
                (Some("MSFT"), "Microsoft", "Azure regions"),
                (Some("GOOGL"), "Alphabet", "GCP regions"),
            ],
            &[
                (None, "Enterprises", "analytics estates"),
                (None, "Financial services", "data clean rooms"),
                (None, "Retail & CPG", "shared data ecosystems"),
            ],
            &["MSFT", "GOOGL", "ORCL", "PLTR"],
        ),
        "PLTR" => p(
            "PLTR", "Palantir Technologies", "Technology", "Analytics Software",
            "United States",
            "Operational AI platforms for defense and industry; AIP has driven rapid \
             US commercial adoption on top of the government franchise.",
            &[
                ("Government", "Gotham for defense and intelligence"),
                ("Commercial", "Foundry operational platform"),
                ("AIP", "AI platform over enterprise data"),
                ("Apollo", "continuous deployment layer"),
            ],
            &[
                (Some("AMZN"), "Amazon", "cloud hosting"),
                (Some("MSFT"), "Microsoft", "Azure/GovCloud hosting"),
                (Some("ORCL"), "Oracle", "distributed-cloud hosting partnership"),
            ],
            &[
                (None, "US DoD & intelligence agencies", "Gotham/Maven contracts"),
                (None, "Allied governments", "defense analytics"),
                (None, "Commercial enterprises", "AIP/Foundry deployments"),
            ],
            &["MSFT", "SNOW", "IBM"],
        ),
        "SHOP" => p(
            "SHOP", "Shopify", "Technology", "E-Commerce Software", "Canada",
            "Commerce operating system for merchants from startups to enterprise \
             brands, monetizing via subscriptions and payments.",
            &[
                ("Merchant Solutions", "payments, shipping, capital"),
                ("Subscriptions", "platform plans"),
                ("POS", "retail hardware and software"),
                ("Enterprise", "Commerce Components for large brands"),
            ],
            &[
                (Some("GOOGL"), "Alphabet", "Google Cloud infrastructure"),
                (None, "Stripe", "payments processing rails"),
                (Some("AFRM"), "Affirm", "Shop Pay Installments BNPL"),
            ],
            &[
                (None, "SMB merchants", "storefronts and payments"),
                (None, "DTC brands", "online retail platform"),
                (None, "Enterprises", "headless commerce"),
            ],
            &["AMZN", "SQ", "WIX"],
        ),
        "UBER" => p(
            "UBER", "Uber Technologies", "Industrials", "Mobility Platform", "United States",
            "Global rides and delivery marketplace, adding advertising and positioning \
             as a demand network for autonomous vehicles.",
            &[
                ("Mobility", "ride-hailing"),
                ("Delivery", "Uber Eats and grocery"),
                ("Freight", "digital brokerage"),
                ("Advertising", "in-app ad inventory"),
            ],
            &[
                (None, "Driver-partners", "ride and courier supply"),
                (Some("GOOGL"), "Alphabet", "maps and cloud services"),
                (Some("ORCL"), "Oracle", "cloud infrastructure"),
            ],
            &[
                (None, "Riders", "mobility demand"),
                (None, "Eaters & merchants", "delivery marketplace"),
                (None, "Shippers", "freight brokerage"),
            ],
            &["LYFT", "DASH", "TSLA"],
        ),
        "ABNB" => p(
            "ABNB", "Airbnb", "Consumer Discretionary", "Travel Marketplace",
            "United States",
            "Two-sided marketplace for stays and experiences, expanding into host \
             services beyond lodging.",
            &[
                ("Stays", "core lodging marketplace"),
                ("Experiences", "local tours and activities"),
                ("Services", "host and guest add-on services"),
            ],
            &[
                (None, "Hosts", "listing supply"),
                (Some("AMZN"), "Amazon", "AWS infrastructure"),
                (None, "Payment processors", "global payouts"),
            ],
            &[
                (None, "Leisure travelers", "short-term stays"),
                (None, "Long-stay guests", "monthly stays and remote work"),
                (None, "Experience seekers", "tours and activities"),
            ],
            &["BKNG", "EXPE", "MAR"],
        ),

        // ── Financials & payments ────────────────────────────────────────
        "JPM" => p(
            "JPM", "JPMorgan Chase", "Financials", "Diversified Bank", "United States",
            "The largest US bank by assets, spanning consumer banking, the top \
             investment-banking franchise and asset management.",
            &[
                ("Consumer & Community Banking", "Chase deposits, cards, mortgages"),
                ("Corporate & Investment Bank", "markets, advisory, payments"),
                ("Commercial Banking", "middle-market lending"),
                ("Asset & Wealth Management", "$3T+ client assets"),
            ],
            &[
                (Some("AMZN"), "Amazon", "public-cloud infrastructure"),
                (Some("V"), "Visa", "card network rails"),
                (Some("MA"), "Mastercard", "card network rails"),
                (None, "Market-data vendors", "Bloomberg/LSEG feeds"),
            ],
            &[
                (None, "Consumers", "deposits, cards, mortgages"),
                (None, "Corporates", "lending, advisory, treasury"),
                (None, "Institutional investors", "markets and custody"),
            ],
            &["BAC", "GS", "MS", "WFC", "C"],
        ),
        "BAC" => p(
            "BAC", "Bank of America", "Financials", "Diversified Bank", "United States",
            "Second-largest US bank; a deposit-rich consumer franchise plus Merrill \
             wealth management and global markets.",
            &[
                ("Consumer Banking", "deposits, cards, lending"),
                ("Global Wealth & Investment Management", "Merrill and private bank"),
                ("Global Banking", "corporate lending and advisory"),
                ("Global Markets", "sales and trading"),
            ],
            &[
                (Some("V"), "Visa", "card network rails"),
                (Some("MA"), "Mastercard", "card network rails"),
                (None, "Market-data vendors", "pricing and reference data"),
            ],
            &[
                (None, "Consumers", "deposits and cards"),
                (None, "Corporates", "lending and treasury"),
                (None, "Institutional investors", "markets and research"),
            ],
            &["JPM", "WFC", "C", "GS"],
        ),
        "GS" => p(
            "GS", "Goldman Sachs", "Financials", "Investment Bank", "United States",
            "Premier advisory and trading house, with a growing asset- and \
             wealth-management arm smoothing its markets-driven earnings.",
            &[
                ("Global Banking & Markets", "M&A advisory, underwriting, trading"),
                ("Asset & Wealth Management", "alternatives and private wealth"),
                ("Platform Solutions", "transaction banking and cards"),
            ],
            &[
                (None, "Market-data vendors", "pricing and reference data"),
                (Some("AMZN"), "Amazon", "cloud infrastructure"),
                (Some("CME"), "CME Group", "derivatives execution and clearing"),
                (Some("ICE"), "Intercontinental Exchange", "exchange venues"),
            ],
            &[
                (None, "Corporates", "M&A advisory and underwriting"),
                (None, "Institutional investors", "trading and prime brokerage"),
                (None, "High-net-worth clients", "wealth management"),
                (Some("AAPL"), "Apple", "Apple Card issuing partnership"),
            ],
            &["MS", "JPM", "BAC", "C"],
        ),
        "MS" => p(
            "MS", "Morgan Stanley", "Financials", "Investment Bank", "United States",
            "Investment bank rebalanced toward durable wealth- and asset-management \
             fees after the E*Trade and Eaton Vance acquisitions.",
            &[
                ("Institutional Securities", "advisory, underwriting, trading"),
                ("Wealth Management", "advisors plus E*Trade self-directed"),
                ("Investment Management", "asset management"),
            ],
            &[
                (None, "Market-data vendors", "pricing and reference data"),
                (Some("MSFT"), "Microsoft", "Azure cloud"),
                (None, "OpenAI", "GPT-based advisor assistants"),
            ],
            &[
                (None, "Corporates", "advisory and capital raising"),
                (None, "Institutional investors", "sales and trading"),
                (None, "Retail investors", "wealth platforms"),
            ],
            &["GS", "JPM", "BAC", "SCHW"],
        ),
        "V" => p(
            "V", "Visa", "Financials", "Payment Network", "United States",
            "The largest card network: a four-party toll road earning fees on \
             authorization, clearing and cross-border volume.",
            &[
                ("Payment Network", "VisaNet authorization and clearing"),
                ("Cross-Border", "international transaction fees"),
                ("Value-Added Services", "risk, issuing and advisory services"),
                ("New Flows", "Visa Direct account-to-account"),
            ],
            &[
                (None, "Data centers & telecom", "network backbone"),
                (None, "Issuer processors", "transaction processing partners"),
                (None, "Cybersecurity vendors", "fraud and risk tooling"),
            ],
            &[
                (Some("JPM"), "JPMorgan Chase", "card issuance volume"),
                (Some("BAC"), "Bank of America", "card issuance volume"),
                (None, "Merchants & acquirers", "acceptance network"),
                (Some("PYPL"), "PayPal", "wallet network partnership"),
                (Some("SQ"), "Block", "Square acquiring rails"),
            ],
            &["MA", "AXP", "PYPL"],
        ),
        "MA" => p(
            "MA", "Mastercard", "Financials", "Payment Network", "United States",
            "Global card network duopolist with Visa, growing services (data, cyber, \
             loyalty) faster than core switching.",
            &[
                ("Payment Network", "authorization, clearing, settlement"),
                ("Cross-Border", "international volume fees"),
                ("Services", "data analytics, cyber, loyalty"),
                ("New Payment Flows", "account-to-account, B2B"),
            ],
            &[
                (None, "Data centers & telecom", "network backbone"),
                (None, "Issuer processors", "transaction processing partners"),
                (None, "Cybersecurity vendors", "fraud and risk tooling"),
            ],
            &[
                (Some("JPM"), "JPMorgan Chase", "card issuance volume"),
                (Some("BAC"), "Bank of America", "card issuance volume"),
                (None, "Merchants & acquirers", "acceptance network"),
                (Some("PYPL"), "PayPal", "wallet network partnership"),
            ],
            &["V", "AXP", "PYPL"],
        ),
        "PYPL" => p(
            "PYPL", "PayPal", "Financials", "Digital Payments", "United States",
            "Two-sided digital wallet and merchant processor: branded checkout, \
             Braintree unbranded processing and Venmo.",
            &[
                ("Branded Checkout", "PayPal button online"),
                ("Braintree", "unbranded enterprise processing"),
                ("Venmo", "P2P and debit monetization"),
                ("Credit", "pay-later and merchant credit"),
            ],
            &[
                (Some("V"), "Visa", "card network rails"),
                (Some("MA"), "Mastercard", "card network rails"),
                (None, "Banking partners", "deposits and settlement"),
            ],
            &[
                (None, "Merchants", "online checkout and processing"),
                (None, "Consumers", "wallets and Venmo"),
                (None, "Platforms & marketplaces", "Braintree processing"),
            ],
            &["SQ", "GPN", "AFRM", "AAPL"],
        ),
        "SQ" => p(
            "SQ", "Block, Inc.", "Financials", "Fintech", "United States",
            "Seller (Square) plus consumer (Cash App) fintech ecosystems with Afterpay \
             BNPL and bitcoin initiatives; trades as XYZ since January 2025.",
            &[
                ("Square", "seller POS and acquiring ecosystem"),
                ("Cash App", "consumer payments and banking"),
                ("Afterpay", "buy-now-pay-later"),
                ("Bitcoin", "Bitkey wallet, Proto mining hardware"),
            ],
            &[
                (Some("V"), "Visa", "card network rails"),
                (Some("MA"), "Mastercard", "card network rails"),
                (None, "Sponsor banks", "card issuing and settlement"),
            ],
            &[
                (None, "SMB sellers", "acquiring and POS"),
                (None, "Cash App consumers", "P2P and banking"),
                (None, "BNPL shoppers", "Afterpay installments"),
            ],
            &["PYPL", "TOST", "FI", "COIN"],
        ),
        "COIN" => p(
            "COIN", "Coinbase", "Financials", "Crypto Exchange", "United States",
            "The largest US-regulated crypto exchange, diversifying from trading fees \
             into USDC economics, custody, derivatives and the Base L2.",
            &[
                ("Trading", "retail and institutional crypto"),
                ("Subscriptions & Services", "USDC interest, staking, custody"),
                ("Base", "Ethereum L2 network"),
                ("Derivatives", "international exchange, Deribit"),
            ],
            &[
                (Some("AMZN"), "Amazon", "AWS infrastructure"),
                (Some("CRCL"), "Circle", "USDC issuance partnership"),
                (None, "Blockchain networks", "protocol infrastructure"),
            ],
            &[
                (None, "Retail traders", "spot and derivatives trading"),
                (None, "Institutions", "custody and prime services"),
                (None, "USDC holders", "stablecoin payments rails"),
            ],
            &["HOOD", "SQ", "PYPL"],
        ),

        // ── Consumer, retail & autos ─────────────────────────────────────
        "WMT" => p(
            "WMT", "Walmart", "Consumer Staples", "Retail", "United States",
            "The world's largest retailer by revenue; grocery scale plus a fast-growing \
             marketplace, advertising and membership flywheel.",
            &[
                ("Walmart US", "supercenters and grocery"),
                ("Sam's Club", "membership warehouse"),
                ("International", "Mexico, Canada, India (Flipkart)"),
                ("E-Commerce & Ads", "marketplace and Walmart Connect"),
            ],
            &[
                (Some("PG"), "Procter & Gamble", "largest CPG supply relationship"),
                (Some("KO"), "Coca-Cola", "beverage supply"),
                (Some("PEP"), "PepsiCo", "snack and beverage supply"),
                (None, "Import suppliers", "general merchandise sourcing"),
            ],
            &[
                (None, "Consumers", "value retail and grocery"),
                (None, "Advertisers", "retail media (Walmart Connect)"),
                (None, "Marketplace sellers", "fulfillment services"),
            ],
            &["AMZN", "COST", "TGT", "KR"],
        ),
        "COST" => p(
            "COST", "Costco Wholesale", "Consumer Staples", "Warehouse Retail",
            "United States",
            "Membership warehouse retailer selling near cost; renewal rates and the \
             Kirkland private label are the moat.",
            &[
                ("Warehouse Clubs", "membership-fee model"),
                ("Kirkland Signature", "private label"),
                ("E-Commerce", "online and delivery"),
                ("Ancillary", "gas, pharmacy, travel"),
            ],
            &[
                (Some("PG"), "Procter & Gamble", "branded staples"),
                (Some("KO"), "Coca-Cola", "beverages"),
                (Some("PEP"), "PepsiCo", "snacks and beverages"),
                (None, "Regional food producers", "fresh and Kirkland supply"),
            ],
            &[
                (None, "Members", "household bulk shopping"),
                (None, "Small businesses", "resale and supplies"),
                (None, "Executive members", "higher-tier spend"),
            ],
            &["WMT", "TGT", "AMZN", "BJ"],
        ),
        "HD" => p(
            "HD", "Home Depot", "Consumer Discretionary", "Home Improvement Retail",
            "United States",
            "The largest home-improvement retailer, increasingly serving professional \
             contractors alongside DIY customers.",
            &[
                ("Building Materials", "lumber, concrete, electrical"),
                ("Décor & Appliances", "kitchen, bath, appliances"),
                ("Tools & Hardware", "power tools and hardware"),
                ("Pro & Services", "Pro Xtra, SRS distribution, rental"),
            ],
            &[
                (Some("SWK"), "Stanley Black & Decker", "DeWalt power tools"),
                (None, "Techtronic Industries", "Ryobi/Milwaukee tools"),
                (Some("MAS"), "Masco", "Behr paint"),
                (Some("WHR"), "Whirlpool", "appliances"),
            ],
            &[
                (None, "DIY consumers", "home projects"),
                (None, "Pro contractors", "job-site supply"),
                (None, "Property managers", "maintenance supply"),
            ],
            &["LOW", "WMT", "AMZN"],
        ),
        "PG" => p(
            "PG", "Procter & Gamble", "Consumer Staples", "Household Products",
            "United States",
            "Branded staples house (Tide, Pampers, Gillette) with pricing power built \
             on daily-use categories and retail shelf dominance.",
            &[
                ("Fabric & Home Care", "Tide, Dawn, Febreze"),
                ("Baby, Feminine & Family", "Pampers, Always, Bounty"),
                ("Beauty", "Olay, Head & Shoulders, SK-II"),
                ("Grooming & Health", "Gillette, Oral-B, Vicks"),
            ],
            &[
                (None, "Chemical suppliers", "surfactants and specialty chemicals"),
                (Some("IP"), "International Paper", "packaging and containerboard"),
                (None, "Pulp suppliers", "tissue and diaper pulp"),
            ],
            &[
                (Some("WMT"), "Walmart", "largest retail channel (~15% of sales)"),
                (Some("COST"), "Costco", "club channel"),
                (Some("TGT"), "Target", "mass retail channel"),
                (Some("KR"), "Kroger", "grocery channel"),
                (Some("AMZN"), "Amazon", "e-commerce channel"),
            ],
            &["UL", "CL", "KMB"],
        ),
        "KO" => p(
            "KO", "The Coca-Cola Company", "Consumer Staples", "Beverages", "United States",
            "Concentrate maker behind the world's most valuable beverage brands, \
             distributing through a franchised global bottling system.",
            &[
                ("Sparkling", "Coca-Cola, Sprite, Fanta"),
                ("Hydration & Sports", "smartwater, Powerade, BodyArmor"),
                ("Juice & Dairy", "Simply, Fairlife"),
                ("Concentrate Operations", "syrup sales to bottlers"),
            ],
            &[
                (None, "Corn refiners", "HFCS sweetener"),
                (Some("BALL"), "Ball Corporation", "aluminum cans"),
                (None, "Sugar producers", "cane and beet sugar"),
            ],
            &[
                (Some("CCEP"), "Coca-Cola Europacific Partners", "concentrate for European bottling"),
                (None, "Franchise bottlers", "global bottling system"),
                (Some("MCD"), "McDonald's", "fountain partnership"),
                (Some("WMT"), "Walmart", "retail channel"),
                (Some("COST"), "Costco", "club channel"),
            ],
            &["PEP", "KDP", "MNST"],
        ),
        "PEP" => p(
            "PEP", "PepsiCo", "Consumer Staples", "Snacks & Beverages", "United States",
            "Snacks-plus-beverages giant — Frito-Lay is the profit engine alongside \
             Pepsi, Gatorade and Quaker.",
            &[
                ("Frito-Lay North America", "Lay's, Doritos, Cheetos"),
                ("PepsiCo Beverages", "Pepsi, Gatorade, Mountain Dew"),
                ("Quaker Foods", "cereals and grains"),
                ("International", "snacks and beverages abroad"),
            ],
            &[
                (None, "Agricultural producers", "corn, potatoes, oats"),
                (Some("BALL"), "Ball Corporation", "aluminum cans"),
                (None, "PET resin suppliers", "bottles"),
            ],
            &[
                (Some("WMT"), "Walmart", "largest customer"),
                (Some("COST"), "Costco", "club channel"),
                (Some("KR"), "Kroger", "grocery channel"),
                (Some("SBUX"), "Starbucks", "ready-to-drink coffee distribution JV"),
            ],
            &["KO", "MDLZ", "KDP"],
        ),
        "NKE" => p(
            "NKE", "Nike", "Consumer Discretionary", "Athletic Footwear & Apparel",
            "United States",
            "The largest sportswear brand, rebalancing from pure direct-to-consumer \
             back toward wholesale partners.",
            &[
                ("Footwear", "performance and lifestyle shoes"),
                ("Apparel", "athletic clothing"),
                ("Jordan Brand", "basketball and lifestyle"),
                ("Converse", "heritage footwear"),
            ],
            &[
                (None, "Pou Chen / Feng Tay", "contract footwear manufacturing"),
                (None, "Shenzhou International", "apparel manufacturing"),
                (None, "Materials suppliers", "knit yarns and cushioning foams"),
            ],
            &[
                (None, "Consumers", "Nike Direct and SNKRS"),
                (Some("FL"), "Foot Locker", "wholesale channel"),
                (Some("DKS"), "Dick's Sporting Goods", "wholesale channel"),
                (Some("AMZN"), "Amazon", "marketplace relaunch"),
            ],
            &["LULU", "DECK", "ONON", "UAA"],
        ),
        "SBUX" => p(
            "SBUX", "Starbucks", "Consumer Discretionary", "Restaurants", "United States",
            "The world's largest coffeehouse chain, executing a back-to-basics US \
             turnaround while licensing packaged coffee globally.",
            &[
                ("North America Retail", "company-operated cafés"),
                ("International", "China and licensed markets"),
                ("Channel Development", "packaged coffee and RTD"),
            ],
            &[
                (None, "Coffee farmers & co-ops", "C.A.F.E.-sourced arabica"),
                (None, "Dairy suppliers", "milk and alternatives"),
                (None, "Packaging suppliers", "cups and packaging"),
            ],
            &[
                (None, "Consumers", "café retail"),
                (None, "Nestlé", "Global Coffee Alliance packaged goods"),
                (Some("PEP"), "PepsiCo", "ready-to-drink distribution JV"),
            ],
            &["MCD", "YUM", "BROS"],
        ),
        "DIS" => p(
            "DIS", "The Walt Disney Company", "Communication Services", "Media & Entertainment",
            "United States",
            "Franchise IP machine spanning studios, streaming, ESPN and the world's \
             top theme parks and cruise line.",
            &[
                ("Entertainment", "studios, Disney+, Hulu"),
                ("Sports", "ESPN and its streaming service"),
                ("Experiences", "parks, cruise line, consumer products"),
            ],
            &[
                (None, "Production studios & talent", "content production"),
                (Some("AMZN"), "Amazon", "AWS cloud/streaming infrastructure"),
                (None, "Shipyards", "cruise fleet expansion"),
            ],
            &[
                (None, "Consumers", "streaming and park attendance"),
                (None, "Advertisers", "ESPN and Hulu inventory"),
                (None, "Theatrical exhibitors", "film distribution"),
                (None, "Licensees", "consumer products"),
            ],
            &["NFLX", "CMCSA", "WBD", "AMZN"],
        ),
        "F" => p(
            "F", "Ford Motor Company", "Consumer Discretionary", "Automobiles",
            "United States",
            "Legacy automaker leaning on trucks (F-Series) and the Ford Pro commercial \
             business while rationalizing its EV losses.",
            &[
                ("Ford Blue", "ICE and hybrid vehicles"),
                ("Model e", "electric vehicles"),
                ("Ford Pro", "commercial vehicles and fleet software"),
                ("Ford Credit", "financing"),
            ],
            &[
                (None, "SK On", "EV battery JV (BlueOval SK)"),
                (None, "CATL", "LFP battery licensing"),
                (None, "Bosch / Continental", "components and electronics"),
                (Some("QCOM"), "Qualcomm", "Snapdragon digital cockpit"),
                (None, "Steel & aluminum suppliers", "body materials"),
            ],
            &[
                (None, "Consumers via dealers", "retail vehicle sales"),
                (None, "Commercial fleets", "Ford Pro vans and trucks"),
                (None, "Rental companies", "fleet sales"),
            ],
            &["GM", "TSLA", "STLA", "TM"],
        ),
        "GM" => p(
            "GM", "General Motors", "Consumer Discretionary", "Automobiles", "United States",
            "Largest US automaker by volume; trucks and SUVs fund the Ultium EV \
             platform and software ambitions.",
            &[
                ("Trucks & SUVs", "Silverado, Sierra, Tahoe"),
                ("EVs", "Ultium-platform vehicles"),
                ("Software & Services", "OnStar, Super Cruise"),
                ("GM Financial", "financing"),
            ],
            &[
                (None, "LG Energy Solution", "Ultium battery cell JV"),
                (None, "Samsung SDI", "battery JV (Indiana)"),
                (Some("NVDA"), "NVIDIA", "AI factory and ADAS partnership"),
                (Some("QCOM"), "Qualcomm", "Snapdragon cockpit and ride platforms"),
            ],
            &[
                (None, "Consumers via dealers", "retail vehicle sales"),
                (None, "Commercial fleets", "fleet and government sales"),
                (None, "Rental companies", "fleet sales"),
            ],
            &["F", "TSLA", "STLA", "TM"],
        ),
        "TSLA" => p(
            "TSLA", "Tesla", "Consumer Discretionary", "EVs & Energy", "United States",
            "Vertically integrated EV and energy-storage maker whose valuation rests \
             heavily on autonomy (FSD/robotaxi) and Optimus robotics bets.",
            &[
                ("Automotive", "Model 3/Y/S/X, Cybertruck"),
                ("Energy", "Megapack and Powerwall storage"),
                ("FSD & Software", "autonomy and connectivity"),
                ("AI & Robotics", "training compute, Optimus humanoid"),
            ],
            &[
                (None, "Panasonic", "2170 battery cells (Nevada)"),
                (None, "CATL", "LFP battery cells"),
                (None, "LG Energy Solution", "battery cells"),
                (Some("NVDA"), "NVIDIA", "AI training GPUs"),
            ],
            &[
                (None, "Consumers", "direct vehicle sales"),
                (None, "Utilities", "Megapack grid storage"),
                (Some("F"), "Ford", "NACS Supercharger access"),
                (Some("GM"), "General Motors", "NACS Supercharger access"),
            ],
            &["F", "GM", "RIVN"],
        ),

        // ── Health care ──────────────────────────────────────────────────
        "UNH" => p(
            "UNH", "UnitedHealth Group", "Health Care", "Managed Care", "United States",
            "The largest US health insurer combined with Optum's care delivery, PBM \
             and health-IT arms — a vertically integrated healthcare stack.",
            &[
                ("UnitedHealthcare", "employer, Medicare and Medicaid plans"),
                ("Optum Health", "care delivery and physician groups"),
                ("Optum Rx", "pharmacy benefit management"),
                ("Optum Insight", "health data and IT"),
            ],
            &[
                (None, "Hospital systems", "network care delivery"),
                (Some("MCK"), "McKesson", "drug distribution"),
                (Some("LLY"), "Eli Lilly", "formulary pharmaceuticals"),
                (Some("PFE"), "Pfizer", "formulary pharmaceuticals"),
            ],
            &[
                (None, "Employers", "group health plans"),
                (None, "CMS", "Medicare Advantage and Medicaid"),
                (None, "Members", "premiums and care"),
            ],
            &["CVS", "CI", "ELV", "HUM"],
        ),
        "LLY" => p(
            "LLY", "Eli Lilly", "Health Care", "Pharmaceuticals", "United States",
            "The most valuable pharma company, powered by the Mounjaro/Zepbound \
             incretin franchise and a deep obesity/Alzheimer's pipeline.",
            &[
                ("Cardiometabolic", "Mounjaro/Zepbound incretins"),
                ("Oncology", "Verzenio and pipeline"),
                ("Neuroscience", "Kisunla (donanemab)"),
                ("Immunology", "Taltz, Omvoh"),
            ],
            &[
                (None, "CDMOs", "contract manufacturing capacity"),
                (None, "API suppliers", "active ingredients"),
                (None, "Device suppliers", "autoinjector components"),
            ],
            &[
                (Some("MCK"), "McKesson", "pharmaceutical distribution"),
                (Some("COR"), "Cencora", "pharmaceutical distribution"),
                (Some("CAH"), "Cardinal Health", "pharmaceutical distribution"),
                (Some("UNH"), "UnitedHealth (Optum Rx)", "PBM formulary access"),
                (Some("CVS"), "CVS Health", "PBM and pharmacy channel"),
            ],
            &["NVO", "MRK", "PFE", "ABBV"],
        ),
        "ABBV" => p(
            "ABBV", "AbbVie", "Health Care", "Pharmaceuticals", "United States",
            "Immunology leader that successfully bridged the Humira patent cliff with \
             Skyrizi and Rinvoq; also owns the Botox aesthetics franchise.",
            &[
                ("Immunology", "Skyrizi, Rinvoq post-Humira"),
                ("Oncology", "Venclexta, ADCs"),
                ("Neuroscience", "Vraylar, migraine portfolio"),
                ("Aesthetics", "Botox, Juvederm"),
            ],
            &[
                (None, "CDMOs", "contract manufacturing"),
                (None, "API suppliers", "active ingredients"),
                (None, "Packaging suppliers", "sterile fill-finish"),
            ],
            &[
                (Some("MCK"), "McKesson", "pharmaceutical distribution"),
                (Some("COR"), "Cencora", "pharmaceutical distribution"),
                (Some("CAH"), "Cardinal Health", "pharmaceutical distribution"),
                (None, "Health systems", "hospital formularies"),
            ],
            &["JNJ", "MRK", "PFE", "AMGN"],
        ),
        "MRK" => p(
            "MRK", "Merck & Co.", "Health Care", "Pharmaceuticals", "United States",
            "Oncology powerhouse anchored by Keytruda — the world's top-selling drug — \
             while building a pipeline for its patent expiry.",
            &[
                ("Oncology", "Keytruda and ADC partnerships"),
                ("Vaccines", "Gardasil, pneumococcal"),
                ("Cardiometabolic", "Winrevair"),
                ("Animal Health", "livestock and companion animals"),
            ],
            &[
                (None, "CDMOs", "contract manufacturing"),
                (None, "API suppliers", "active ingredients"),
                (None, "Cold-chain logistics", "vaccine distribution"),
            ],
            &[
                (Some("MCK"), "McKesson", "pharmaceutical distribution"),
                (Some("COR"), "Cencora", "pharmaceutical distribution"),
                (Some("CAH"), "Cardinal Health", "pharmaceutical distribution"),
                (None, "Governments", "vaccine procurement"),
            ],
            &["PFE", "BMY", "LLY", "ABBV"],
        ),
        "PFE" => p(
            "PFE", "Pfizer", "Health Care", "Pharmaceuticals", "United States",
            "Diversified pharma rebuilding growth after the COVID revenue cliff, with \
             the Seagen acquisition anchoring its oncology push.",
            &[
                ("Vaccines", "Comirnaty, Prevnar, RSV"),
                ("Oncology", "Seagen ADCs, Ibrance"),
                ("Specialty", "inflammation and rare disease"),
                ("Internal Medicine", "Eliquis, migraine"),
            ],
            &[
                (None, "CDMOs", "contract manufacturing"),
                (None, "API suppliers", "active ingredients"),
                (None, "Lipid/biologics suppliers", "mRNA and biologics inputs"),
            ],
            &[
                (Some("MCK"), "McKesson", "pharmaceutical distribution"),
                (Some("COR"), "Cencora", "pharmaceutical distribution"),
                (Some("CAH"), "Cardinal Health", "pharmaceutical distribution"),
                (None, "Governments", "vaccine procurement"),
            ],
            &["MRK", "LLY", "ABBV", "BMY"],
        ),

        // ── Energy, industrials & defense ────────────────────────────────
        "XOM" => p(
            "XOM", "Exxon Mobil", "Energy", "Integrated Oil & Gas", "United States",
            "The largest western oil major; Permian scale (Pioneer acquisition) plus \
             the prolific Guyana development drive low-cost barrels.",
            &[
                ("Upstream", "Permian and Guyana production"),
                ("Product Solutions", "refining and fuels"),
                ("Chemicals", "petrochemicals"),
                ("Low Carbon", "CCS, hydrogen, lithium"),
            ],
            &[
                (Some("SLB"), "SLB", "oilfield services"),
                (Some("HAL"), "Halliburton", "fracking and completions"),
                (Some("BKR"), "Baker Hughes", "drilling equipment and services"),
            ],
            &[
                (None, "Refiners & marketers", "crude offtake"),
                (None, "Airlines", "jet fuel"),
                (None, "Chemical & industrial buyers", "feedstocks"),
                (None, "Utilities", "natural gas"),
            ],
            &["CVX", "SHEL", "BP", "COP"],
        ),
        "CVX" => p(
            "CVX", "Chevron", "Energy", "Integrated Oil & Gas", "United States",
            "US oil major with Permian, Tengiz and — via the Hess acquisition — a \
             stake in Guyana's premier offshore development.",
            &[
                ("Upstream", "Permian, Tengiz, Gulf of Mexico, Guyana (Hess)"),
                ("Downstream", "refining and marketing"),
                ("Chemicals", "CPChem joint venture"),
                ("New Energies", "renewable fuels, hydrogen"),
            ],
            &[
                (Some("SLB"), "SLB", "oilfield services"),
                (Some("HAL"), "Halliburton", "completions"),
                (Some("BKR"), "Baker Hughes", "equipment and services"),
            ],
            &[
                (None, "Refiners & marketers", "crude offtake"),
                (None, "Airlines", "jet fuel"),
                (None, "Utilities", "natural gas and LNG"),
            ],
            &["XOM", "SHEL", "BP", "COP"],
        ),
        "CAT" => p(
            "CAT", "Caterpillar", "Industrials", "Machinery", "United States",
            "The world's largest construction and mining equipment maker; its engine \
             and turbine business now also powers data-center backup generation.",
            &[
                ("Construction Industries", "excavators, loaders, dozers"),
                ("Resource Industries", "mining trucks and autonomous haulage"),
                ("Energy & Transportation", "engines, turbines, gensets"),
                ("Cat Financial", "equipment financing"),
            ],
            &[
                (None, "Steel & castings suppliers", "structural components"),
                (None, "Component suppliers", "hydraulics and drivetrain"),
                (None, "Electronics suppliers", "autonomy sensors and controls"),
            ],
            &[
                (None, "Cat dealer network", "global distribution"),
                (None, "Mining companies", "autonomous haul fleets"),
                (None, "Construction firms", "equipment fleets"),
                (None, "Data centers", "backup power gensets"),
            ],
            &["DE", "CMI"],
        ),
        "BA" => p(
            "BA", "Boeing", "Industrials", "Aerospace & Defense", "United States",
            "One half of the commercial-aircraft duopoly with Airbus, working through \
             production-quality recovery on the 737 MAX and 787.",
            &[
                ("Commercial Airplanes", "737 MAX, 787, 777X"),
                ("Defense, Space & Security", "fighters, tankers, satellites"),
                ("Global Services", "parts, maintenance, training"),
            ],
            &[
                (Some("GE"), "GE Aerospace", "LEAP engines (CFM)"),
                (Some("RTX"), "RTX (Collins/Pratt)", "aerostructures, avionics, engines"),
                (Some("SPR"), "Spirit AeroSystems", "fuselage structures"),
                (Some("HON"), "Honeywell", "avionics and APUs"),
                (Some("HWM"), "Howmet Aerospace", "fasteners and structures"),
            ],
            &[
                (Some("DAL"), "Delta Air Lines", "aircraft orders"),
                (Some("UAL"), "United Airlines", "737/787 orders"),
                (Some("AAL"), "American Airlines", "aircraft orders"),
                (Some("LUV"), "Southwest Airlines", "737 fleet"),
                (None, "Aircraft lessors", "AerCap and peers"),
                (None, "US DoD", "defense programs"),
            ],
            &["LMT", "NOC", "GD"],
        ),
        "GE" => p(
            "GE", "GE Aerospace", "Industrials", "Aerospace", "United States",
            "Pure-play jet-engine maker after the GE breakup; the CFM LEAP franchise \
             and its services annuity power the business.",
            &[
                ("Commercial Engines & Services", "LEAP (CFM JV with Safran), GEnx"),
                ("Defense & Propulsion", "military engines"),
                ("Services", "long-term maintenance annuity"),
            ],
            &[
                (Some("HWM"), "Howmet Aerospace", "airfoils and forgings"),
                (None, "Safran", "CFM International 50/50 partner"),
                (None, "Specialty alloy suppliers", "superalloys"),
            ],
            &[
                (Some("BA"), "Boeing", "LEAP-1B for 737 MAX"),
                (None, "Airbus", "LEAP-1A for A320neo"),
                (Some("DAL"), "Delta Air Lines", "engine services and MRO"),
                (None, "US DoD", "military engines"),
            ],
            &["RTX", "HON", "HEI"],
        ),
        "HON" => p(
            "HON", "Honeywell", "Industrials", "Diversified Industrial", "United States",
            "Diversified industrial spanning aerospace, automation and energy \
             technologies, in the middle of a planned three-way breakup.",
            &[
                ("Aerospace Technologies", "avionics, APUs, engines"),
                ("Industrial Automation", "sensors, process controls"),
                ("Building Automation", "building controls and security"),
                ("Energy & Sustainability", "UOP process technology"),
            ],
            &[
                (None, "Semiconductor suppliers", "electronics content"),
                (None, "Machined-parts suppliers", "precision components"),
                (None, "Materials suppliers", "specialty materials"),
            ],
            &[
                (Some("BA"), "Boeing", "avionics and APUs"),
                (None, "Airbus", "avionics"),
                (None, "Building owners", "automation and controls"),
                (None, "Energy sector", "UOP process licenses"),
            ],
            &["GE", "RTX", "EMR"],
        ),
        "LMT" => p(
            "LMT", "Lockheed Martin", "Industrials", "Defense", "United States",
            "The largest pure defense prime; the F-35 program plus missiles and space \
             anchor a government-funded backlog.",
            &[
                ("Aeronautics", "F-35, F-16"),
                ("Missiles & Fire Control", "HIMARS, PAC-3, hypersonics"),
                ("Rotary & Mission Systems", "Sikorsky helicopters, Aegis"),
                ("Space", "satellites, Orion"),
            ],
            &[
                (Some("RTX"), "RTX", "subsystems and electronics"),
                (Some("HON"), "Honeywell", "avionics"),
                (Some("HWM"), "Howmet Aerospace", "aerostructures and fasteners"),
                (None, "Titanium suppliers", "airframe materials"),
            ],
            &[
                (None, "US DoD", "roughly three-quarters of revenue"),
                (None, "Allied governments", "foreign military sales (F-35 partners)"),
                (None, "NASA & space agencies", "Orion and satellites"),
            ],
            &["NOC", "GD", "RTX", "BA"],
        ),

        // ── Communications ───────────────────────────────────────────────
        "VZ" => p(
            "VZ", "Verizon Communications", "Communication Services", "Telecom",
            "United States",
            "The largest US wireless carrier by subscribers, pairing premium postpaid \
             mobility with Fios and fixed-wireless broadband.",
            &[
                ("Consumer Wireless", "postpaid mobility"),
                ("Business", "enterprise connectivity and edge"),
                ("Broadband", "Fios fiber plus fixed wireless access"),
            ],
            &[
                (Some("AAPL"), "Apple", "iPhone handset inventory"),
                (None, "Ericsson / Nokia", "RAN network equipment"),
                (Some("GLW"), "Corning", "optical fiber"),
                (None, "Samsung Electronics", "network gear and handsets"),
            ],
            &[
                (None, "Consumers", "postpaid wireless plans"),
                (None, "Enterprises", "connectivity and private networks"),
                (None, "Government", "public-sector networks"),
            ],
            &["T", "TMUS", "CMCSA"],
        ),

        // ── Index funds ──────────────────────────────────────────────────
        "SPY" => p(
            "SPY", "SPDR S&P 500 ETF Trust", "Index Fund", "Large-Cap Blend ETF",
            "United States",
            "The oldest and most-traded US ETF, tracking the S&P 500. An index fund — \
             supply-chain analysis does not apply.",
            &[
                ("Top holdings", "NVDA, MSFT, AAPL, AMZN, GOOGL — mega-cap concentration"),
                ("Sector tilt", "information technology is the largest weight"),
                ("Structure", "unit investment trust, full S&P 500 replication"),
            ],
            &[],
            &[],
            &["VOO", "IVV", "QQQ"],
        ),
        "QQQ" => p(
            "QQQ", "Invesco QQQ Trust", "Index Fund", "Large-Cap Growth ETF",
            "United States",
            "Tracks the Nasdaq-100 — the largest non-financial Nasdaq names. An index \
             fund — supply-chain analysis does not apply.",
            &[
                ("Top holdings", "NVDA, MSFT, AAPL, AVGO, AMZN"),
                ("Profile", "growth and technology heavy; excludes financials"),
                ("Structure", "unit investment trust tracking the Nasdaq-100"),
            ],
            &[],
            &[],
            &["SPY", "VGT", "XLK"],
        ),

        _ => return None,
    };
    Some(c)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// US-listed tickers referenced in relations/competitors that are not
    /// themselves in the curated set. Every entry is a well-known,
    /// exchange-listed symbol.
    const WELL_KNOWN: &[&str] = &[
        // Tech & semis
        "GLW", "HPQ", "HPE", "SONY", "GFS", "UMC", "AMAT", "LRCX", "KLAC", "ADI", "NXPI", "ON",
        "MCHP", "SNDK", "WDC", "STX", "MRVL", "SNAP", "FIG", "SAP", "NOW", "IBM", "WIX", "CRWV",
        // Telecom & media
        "TMUS", "T", "CMCSA", "WBD",
        // Financials & fintech
        "WFC", "C", "SCHW", "AXP", "GPN", "AFRM", "TOST", "FI", "HOOD", "CRCL", "CME", "ICE",
        // Consumer & retail
        "BBY", "TGT", "KR", "LOW", "BJ", "SWK", "MAS", "WHR", "IP", "UL", "CL", "KMB", "BALL",
        "CCEP", "MCD", "KDP", "MNST", "MDLZ", "YUM", "BROS", "FL", "DKS", "LULU", "DECK",
        "ONON", "UAA",
        // Autos & travel
        "STLA", "TM", "RIVN", "LYFT", "DASH", "BKNG", "EXPE", "MAR",
        // Health care
        "CVS", "CI", "ELV", "HUM", "MCK", "COR", "CAH", "NVO", "JNJ", "AMGN", "BMY",
        // Energy & industrials
        "SLB", "HAL", "BKR", "SHEL", "BP", "COP", "DE", "CMI", "RTX", "SPR", "NOC", "GD",
        "DAL", "UAL", "AAL", "LUV", "HWM", "HEI", "EMR",
        // ETFs
        "VOO", "IVV", "VGT", "XLK",
    ];

    #[test]
    fn curated_hits_for_flagships() {
        for sym in ["NVDA", "AAPL"] {
            let c = curated(sym).unwrap();
            assert_eq!(c.symbol, sym);
            assert!(!c.suppliers.is_empty(), "{sym} suppliers");
            assert!(!c.customers.is_empty(), "{sym} customers");
            assert!(!c.segments.is_empty(), "{sym} segments");
            assert!(!c.competitors.is_empty(), "{sym} competitors");
            assert_eq!(c.graph_source, GRAPH_SOURCE);
            assert!(c.fundamentals.is_none());
        }
        // NVDA supply chain sanity: TSMC upstream, hyperscalers downstream.
        let nvda = curated("NVDA").unwrap();
        assert!(nvda.suppliers.iter().any(|r| r.symbol.as_deref() == Some("TSM")));
        assert!(nvda.customers.iter().any(|r| r.symbol.as_deref() == Some("MSFT")));
    }

    #[test]
    fn curated_misses_for_unknown() {
        assert!(curated("ZZZZ").is_none());
        assert!(curated("BTC-USD").is_none());
        assert!(curated("nvda").is_none()); // callers uppercase first
    }

    #[test]
    fn curated_universe_is_consistent() {
        let known: HashSet<&str> = CURATED_SYMBOLS
            .iter()
            .chain(WELL_KNOWN.iter())
            .copied()
            .collect();
        assert!(CURATED_SYMBOLS.len() >= 58, "curated set shrank");

        for sym in CURATED_SYMBOLS {
            let c = curated(sym).unwrap_or_else(|| panic!("{sym} missing from curated()"));
            assert_eq!(&c.symbol, sym);
            assert!(!c.name.is_empty() && !c.sector.is_empty(), "{sym} identity");
            assert!(!c.description.is_empty(), "{sym} description");
            assert_eq!(c.graph_source, GRAPH_SOURCE, "{sym} source label");

            let etf = c.sector == "Index Fund";
            assert!(
                (3..=6).contains(&c.segments.len()),
                "{sym} segments count {}",
                c.segments.len()
            );
            if etf {
                assert!(c.suppliers.is_empty() && c.customers.is_empty(), "{sym} ETF relations");
            } else {
                assert!((3..=8).contains(&c.suppliers.len()), "{sym} suppliers count");
                assert!((3..=8).contains(&c.customers.len()), "{sym} customers count");
            }
            assert!((2..=6).contains(&c.competitors.len()), "{sym} competitors count");

            for rel in c.suppliers.iter().chain(c.customers.iter()) {
                assert!(!rel.name.is_empty() && !rel.via.is_empty(), "{sym} relation text");
                if let Some(target) = &rel.symbol {
                    assert!(
                        known.contains(target.as_str()),
                        "{sym} relation points at unknown ticker {target}"
                    );
                }
            }
            for comp in &c.competitors {
                assert!(
                    known.contains(comp.as_str()),
                    "{sym} competitor is unknown ticker {comp}"
                );
                assert_ne!(comp, sym, "{sym} competes with itself");
            }
        }
    }
}
