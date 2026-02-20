"""Price alert monitoring engine."""
from __future__ import annotations
import asyncio
from dataclasses import dataclass, field
from enum import Enum
from typing import Any
import time
import structlog

logger = structlog.get_logger(__name__)


class AlertType(str, Enum):
    PRICE_ABOVE = "price_above"
    PRICE_BELOW = "price_below"
    PCT_CHANGE = "pct_change"


class AlertStatus(str, Enum):
    ACTIVE = "active"
    TRIGGERED = "triggered"
    DISMISSED = "dismissed"


@dataclass
class Alert:
    id: str
    symbol: str
    alert_type: AlertType
    threshold: float
    status: AlertStatus = AlertStatus.ACTIVE
    created_at: float = field(default_factory=time.time)
    triggered_at: float | None = None
    message: str = ""


class AlertEngine:
    """Monitors price data and triggers alerts when conditions are met."""

    def __init__(self) -> None:
        self._alerts: dict[str, Alert] = {}
        self._last_prices: dict[str, float] = {}
        self._base_prices: dict[str, float] = {}  # for pct_change
        self._broadcast_fn = None

    def set_broadcast(self, fn) -> None:
        self._broadcast_fn = fn

    def create_alert(self, alert_id: str, symbol: str, alert_type: str, threshold: float) -> Alert:
        alert = Alert(
            id=alert_id,
            symbol=symbol.upper(),
            alert_type=AlertType(alert_type),
            threshold=threshold,
        )
        self._alerts[alert_id] = alert
        logger.info("alert_created", alert_id=alert_id, symbol=symbol, type=alert_type, threshold=threshold)
        return alert

    def delete_alert(self, alert_id: str) -> bool:
        if alert_id in self._alerts:
            del self._alerts[alert_id]
            return True
        return False

    def get_alerts(self, symbol: str | None = None) -> list[Alert]:
        alerts = list(self._alerts.values())
        if symbol:
            alerts = [a for a in alerts if a.symbol == symbol.upper()]
        return alerts

    def update_price(self, symbol: str, price: float) -> list[Alert]:
        """Update price and check all active alerts. Returns newly triggered alerts."""
        symbol = symbol.upper()
        old_price = self._last_prices.get(symbol)
        self._last_prices[symbol] = price
        if symbol not in self._base_prices:
            self._base_prices[symbol] = price

        triggered = []
        for alert in self._alerts.values():
            if alert.symbol != symbol or alert.status != AlertStatus.ACTIVE:
                continue

            if self._check_condition(alert, price, old_price):
                alert.status = AlertStatus.TRIGGERED
                alert.triggered_at = time.time()
                alert.message = self._build_message(alert, price)
                triggered.append(alert)
                logger.info("alert_triggered", alert_id=alert.id, symbol=symbol, price=price)

        return triggered

    def _check_condition(self, alert: Alert, price: float, old_price: float | None) -> bool:
        if alert.alert_type == AlertType.PRICE_ABOVE:
            return price >= alert.threshold
        elif alert.alert_type == AlertType.PRICE_BELOW:
            return price <= alert.threshold
        elif alert.alert_type == AlertType.PCT_CHANGE:
            base = self._base_prices.get(alert.symbol, 0)
            if base == 0:
                return False
            pct = abs((price - base) / base) * 100
            return pct >= alert.threshold
        return False

    def _build_message(self, alert: Alert, price: float) -> str:
        if alert.alert_type == AlertType.PRICE_ABOVE:
            return f"{alert.symbol} crossed above ${alert.threshold:.2f} (now ${price:.2f})"
        elif alert.alert_type == AlertType.PRICE_BELOW:
            return f"{alert.symbol} dropped below ${alert.threshold:.2f} (now ${price:.2f})"
        elif alert.alert_type == AlertType.PCT_CHANGE:
            base = self._base_prices.get(alert.symbol, price)
            pct = ((price - base) / base) * 100 if base else 0
            return f"{alert.symbol} moved {pct:+.1f}% (now ${price:.2f})"
        return f"{alert.symbol} alert triggered at ${price:.2f}"

    async def broadcast_triggered(self, triggered: list[Alert]) -> None:
        if not self._broadcast_fn or not triggered:
            return
        for alert in triggered:
            await self._broadcast_fn({
                "type": "alert_triggered",
                "payload": {
                    "id": alert.id,
                    "symbol": alert.symbol,
                    "alert_type": alert.alert_type.value,
                    "threshold": alert.threshold,
                    "message": alert.message,
                    "triggered_at": alert.triggered_at,
                },
            })
