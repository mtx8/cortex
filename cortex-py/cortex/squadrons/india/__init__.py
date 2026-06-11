"""INDIA squadron — geospatial alt-data / physical alpha.

Consumes maritime AIS + seismic geo signals (ingested by the geo feed through the
hardened Rust egress) and turns them into actionable, leading trading signals that
Bloomberg cannot natively produce. Routes through the SignalBus only (CLAUDE.md
rule #2); every auto-action stays behind the kill switch + autonomy dial.
"""

from cortex.squadrons.india.maritime_analyst import MaritimeAnalyst
from cortex.squadrons.india.geo_risk_mapper import GeoRiskMapper

__all__ = ["MaritimeAnalyst", "GeoRiskMapper"]
