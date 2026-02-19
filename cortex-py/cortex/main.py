import uvloop
uvloop.install()

from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import structlog

from cortex.config import CortexConfig

log = structlog.get_logger()
config = CortexConfig()


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("cortex.starting", ws_port=config.ws_port)
    yield
    log.info("cortex.shutdown")


app = FastAPI(title="CORTEX", lifespan=lifespan)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    log.info("ws.connected")
    try:
        while True:
            data = await ws.receive_bytes()
            await ws.send_bytes(data)  # Echo for now
    except WebSocketDisconnect:
        log.info("ws.disconnected")


def create_app_components() -> dict:
    """Create and wire all CORTEX components. Returns dict of key components."""
    from cortex.orchestrator.bus import SignalBus
    from cortex.orchestrator.autonomy import AutonomyDial
    from cortex.orchestrator.trade_pipeline import TradePipeline
    from cortex.orchestrator.system import SystemOrchestrator
    from cortex.squadrons.echo.risk_guardian import RiskGuardian
    from cortex.squadrons.echo.kill_switch import KillSwitchCommander
    from cortex.squadrons.echo.risk_checks import PreTradeCheck
    from cortex.squadrons.echo.position_sizer import PositionSizer
    from cortex.squadrons.echo.drawdown_shield import DrawdownShield
    from cortex.squadrons.alpha.signal_hunter import SignalHunter
    from cortex.squadrons.delta.news_catalyst import NewsCatalyst
    from cortex.api.ws_broadcaster import WSBroadcaster

    bus = SignalBus()
    autonomy = AutonomyDial()

    # ECHO squadron
    kill_switch = KillSwitchCommander(bus=bus)
    guardian = RiskGuardian(
        bus=bus,
        kill_switch_check=lambda: kill_switch.is_halted,
        pre_trade=PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50),
        position_sizer=PositionSizer(max_position_pct=5.0, max_single_loss_usd=500.0),
        drawdown_shield=DrawdownShield(),
    )

    # TradePipeline
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    # System orchestrator
    orchestrator = SystemOrchestrator(bus=bus, autonomy=autonomy)

    # Register all agents
    orchestrator.register_agent(kill_switch)

    # ALPHA squadron
    signal_hunter = SignalHunter(bus=bus)
    orchestrator.register_agent(signal_hunter)

    # DELTA squadron
    news_catalyst = NewsCatalyst(bus=bus)
    orchestrator.register_agent(news_catalyst)

    # WebSocket broadcaster
    broadcaster = WSBroadcaster(bus=bus)

    return {
        "bus": bus,
        "autonomy": autonomy,
        "kill_switch": kill_switch,
        "guardian": guardian,
        "pipeline": pipeline,
        "orchestrator": orchestrator,
        "broadcaster": broadcaster,
    }
