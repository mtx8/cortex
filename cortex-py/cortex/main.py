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

    # Start market data feed if available
    feed_task = None
    market_feed = components.get("market_feed")
    if market_feed is not None:
        feed_task = asyncio.create_task(market_feed.start())

    # Start status broadcaster if available
    status_task = None
    status_broadcaster = components.get("status_broadcaster")
    if status_broadcaster is not None:
        status_task = asyncio.create_task(status_broadcaster.start())

    yield

    # Graceful shutdown
    if status_broadcaster is not None:
        await status_broadcaster.stop()
    if status_task is not None:
        status_task.cancel()
        try:
            await status_task
        except asyncio.CancelledError:
            pass

    if market_feed is not None:
        await market_feed.stop()
    if feed_task is not None:
        feed_task.cancel()
        try:
            await feed_task
        except asyncio.CancelledError:
            pass

    await orchestrator.stop()
    orch_task.cancel()
    try:
        await orch_task
    except asyncio.CancelledError:
        pass

    # Close polygon client if present
    polygon_client = components.get("polygon_client")
    if polygon_client is not None:
        await polygon_client.close()

    log.info("cortex.shutdown")


app = FastAPI(title="CORTEX", lifespan=lifespan)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    components = ws.app.state.components
    broadcaster = components["broadcaster"]
    kill_switch = components["kill_switch"]
    autonomy = components["autonomy"]
    chat = components.get("chat")
    polygon_client = components.get("polygon_client")

    broadcaster.add_client(ws)
    log.info("ws.connected", clients=broadcaster.client_count)

    try:
        while True:
            data = await ws.receive_json()

            from cortex.api.protocol import (
                MessageType, CortexMessage, decode_message, encode_message,
            )

            msg = decode_message(data)

            if msg.type == MessageType.CMD_KILL_SWITCH:
                reason = msg.payload.get("reason", "manual")
                await kill_switch.engage(reason=reason, triggered_by="ws_client")
                log.info("ws.kill_switch_engaged", reason=reason)

            elif msg.type == MessageType.CMD_DISENGAGE_KILL:
                kill_switch.disengage(operator="ws_client")
                log.info("ws.kill_switch_disengaged")

            elif msg.type == MessageType.CMD_SET_AUTONOMY:
                from cortex.orchestrator.autonomy import AutonomyLevel

                level_value = msg.payload.get("level", 1)
                autonomy.set_level(AutonomyLevel(level_value))
                log.info("ws.autonomy_set", level=autonomy.level.name)

            elif msg.type == MessageType.CMD_CHAT_MESSAGE:
                if chat is not None:
                    user_text = msg.payload.get("message", "")
                    conversation_id = msg.payload.get("conversation_id", "default")
                    log.info(
                        "ws.chat_message",
                        length=len(user_text),
                        conversation_id=conversation_id,
                    )
                    # Stream Claude response chunks back to the client
                    try:
                        async for chunk in chat.stream_response(
                            user_message=user_text,
                            conversation_id=conversation_id,
                        ):
                            chunk_msg = CortexMessage(
                                type=MessageType.CHAT_CHUNK,
                                payload={
                                    "chunk": chunk,
                                    "conversation_id": conversation_id,
                                    "done": False,
                                },
                            )
                            await ws.send_text(encode_message(chunk_msg))

                        # Send final done message
                        done_msg = CortexMessage(
                            type=MessageType.CHAT_CHUNK,
                            payload={
                                "chunk": "",
                                "conversation_id": conversation_id,
                                "done": True,
                            },
                        )
                        await ws.send_text(encode_message(done_msg))
                    except Exception as e:
                        log.error("ws.chat_error", error=str(e))
                        err_msg = CortexMessage(
                            type=MessageType.CHAT_RESPONSE,
                            payload={
                                "error": str(e),
                                "conversation_id": conversation_id,
                            },
                        )
                        await ws.send_text(encode_message(err_msg))

            elif msg.type == MessageType.CMD_SEARCH_TICKER:
                if polygon_client is not None:
                    query = msg.payload.get("query", "")
                    log.info("ws.search_ticker", query=query)
                    try:
                        results = await polygon_client.search_tickers(query)
                        result_msg = CortexMessage(
                            type=MessageType.TICKER_SEARCH_RESULTS,
                            payload={"query": query, "results": results},
                        )
                        await ws.send_text(encode_message(result_msg))
                    except Exception as e:
                        log.error("ws.search_error", error=str(e))
                        err_msg = CortexMessage(
                            type=MessageType.TICKER_SEARCH_RESULTS,
                            payload={"query": query, "results": [], "error": str(e)},
                        )
                        await ws.send_text(encode_message(err_msg))

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
    from cortex.connectors.polygon.rest_client import PolygonRESTClient
    from cortex.feeds.market_data import MarketDataFeed
    from cortex.intelligence.chat import CortexChat
    from cortex.feeds.status_broadcaster import StatusBroadcaster

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

    # Polygon REST client
    polygon_client = PolygonRESTClient(api_key=config.polygon_api_key)

    # Market data feed
    market_feed = MarketDataFeed(
        polygon_client=polygon_client,
        broadcaster=broadcaster,
        bus=bus,
    )

    # Claude chat interface
    chat = CortexChat(
        api_key=config.anthropic_api_key,
        model=config.claude_model,
        bus=bus,
    )

    # Periodic status broadcaster
    status_broadcaster = StatusBroadcaster(
        broadcaster=broadcaster,
        orchestrator=orchestrator,
        interval=5.0,
    )

    return {
        "bus": bus,
        "autonomy": autonomy,
        "kill_switch": kill_switch,
        "guardian": guardian,
        "pipeline": pipeline,
        "orchestrator": orchestrator,
        "broadcaster": broadcaster,
        "polygon_client": polygon_client,
        "market_feed": market_feed,
        "chat": chat,
        "status_broadcaster": status_broadcaster,
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("cortex.main:app", host="127.0.0.1", port=8765, reload=True)
