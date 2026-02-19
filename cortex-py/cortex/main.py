try:
    import uvloop  # noqa: F401 — uvicorn picks it up automatically
except ImportError:
    pass  # uvloop is optional; uvicorn falls back to asyncio

import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import structlog

from cortex.config import CortexConfig

log = structlog.get_logger()
config = CortexConfig()


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("cortex.starting", ws_port=config.ws_port)

    # Create and wire all components
    components = create_app_components()
    app.state.components = components

    bus = components["bus"]
    broadcaster = components["broadcaster"]
    orchestrator = components["orchestrator"]

    # Subscribe broadcaster to every signal on the bus
    bus.subscribe_all(broadcaster.handle_bus_signal)

    # Start the orchestrator (runs the signal bus) as a background task
    orch_task = asyncio.create_task(orchestrator.start())

    yield

    # Graceful shutdown
    await orchestrator.stop()
    orch_task.cancel()
    try:
        await orch_task
    except asyncio.CancelledError:
        pass

    log.info("cortex.shutdown")


app = FastAPI(title="CORTEX", lifespan=lifespan)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    components = ws.app.state.components
    broadcaster = components["broadcaster"]
    kill_switch = components["kill_switch"]
    autonomy = components["autonomy"]

    broadcaster.add_client(ws)
    log.info("ws.connected", clients=broadcaster.client_count)

    try:
        while True:
            data = await ws.receive_bytes()

            from cortex.api.protocol import MessageType, decode_message

            msg = decode_message(data)

            if msg.type == MessageType.CMD_KILL_SWITCH:
                # Engage kill switch
                reason = msg.payload.get("reason", "manual")
                await kill_switch.engage(reason=reason, triggered_by="ws_client")
                log.info("ws.kill_switch_engaged", reason=reason)

            elif msg.type == MessageType.CMD_DISENGAGE_KILL:
                # Disengage kill switch
                kill_switch.disengage(operator="ws_client")
                log.info("ws.kill_switch_disengaged")

            elif msg.type == MessageType.CMD_SET_AUTONOMY:
                from cortex.orchestrator.autonomy import AutonomyLevel

                level_value = msg.payload.get("level", 1)
                autonomy.set_level(AutonomyLevel(level_value))
                log.info("ws.autonomy_set", level=autonomy.level.name)

            else:
                log.debug("ws.unhandled_command", msg_type=msg.type)

    except WebSocketDisconnect:
        broadcaster.remove_client(ws)
        log.info("ws.disconnected", clients=broadcaster.client_count)
    except Exception:
        broadcaster.remove_client(ws)
        raise


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
    from cortex.squadrons.alpha.gap_scanner import GapScanner
    from cortex.squadrons.alpha.volume_profiler import VolumeProfiler
    from cortex.squadrons.bravo.order_sniper import OrderSniper
    from cortex.squadrons.bravo.spread_optimizer import SpreadOptimizer
    from cortex.squadrons.charlie.flow_intelligence import FlowIntelligence
    from cortex.squadrons.charlie.greeks_engine import GreeksAgent
    from cortex.squadrons.foxtrot.wash_sale_guard import WashSaleGuard
    from cortex.squadrons.foxtrot.harvest_bot import HarvestBot
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
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian, autonomy_dial=autonomy)

    # System orchestrator
    orchestrator = SystemOrchestrator(bus=bus, autonomy=autonomy)

    # ── Register ALL agents ──────────────────────────────────────────

    # ECHO squadron
    orchestrator.register_agent(kill_switch)
    orchestrator.register_agent(guardian)

    # ALPHA squadron
    signal_hunter = SignalHunter(bus=bus)
    orchestrator.register_agent(signal_hunter)

    gap_scanner = GapScanner(bus=bus)
    orchestrator.register_agent(gap_scanner)

    volume_profiler = VolumeProfiler(bus=bus)
    orchestrator.register_agent(volume_profiler)

    # BRAVO squadron
    order_sniper = OrderSniper(bus=bus)
    orchestrator.register_agent(order_sniper)

    spread_optimizer = SpreadOptimizer(bus=bus)
    orchestrator.register_agent(spread_optimizer)

    # CHARLIE squadron
    flow_intelligence = FlowIntelligence(bus=bus)
    orchestrator.register_agent(flow_intelligence)

    greeks_agent = GreeksAgent(bus=bus)
    orchestrator.register_agent(greeks_agent)

    # FOXTROT squadron
    wash_sale_guard = WashSaleGuard(bus=bus)
    orchestrator.register_agent(wash_sale_guard)

    harvest_bot = HarvestBot(bus=bus, wash_sale_guard=wash_sale_guard)
    orchestrator.register_agent(harvest_bot)

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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("cortex.main:app", host="127.0.0.1", port=8765, reload=True)
