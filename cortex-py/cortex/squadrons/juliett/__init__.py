"""JULIETT squadron — macro / fixed income.

Consumes Treasury rate structure (ingested by the macro feed) and emits regime +
curve-inversion signals that steer risk appetite and sector tilts. Routes through
the SignalBus only; every auto-action stays behind the kill switch + autonomy dial.
"""

from cortex.squadrons.juliett.rates_analyst import RatesAnalyst

__all__ = ["RatesAnalyst"]
