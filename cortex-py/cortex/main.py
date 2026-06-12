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

    # Start geo-intelligence feed if available (maritime AIS + seismic)
    geo_task = None
    geo_feed = components.get("geo_feed")
    if geo_feed is not None:
        geo_task = asyncio.create_task(geo_feed.start())

    # Start macro / fixed-income feed if available (Treasury rates)
    macro_task = None
    macro_feed = components.get("macro_feed")
    if macro_feed is not None:
        macro_task = asyncio.create_task(macro_feed.start())

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

    if geo_feed is not None:
        await geo_feed.stop()
    if geo_task is not None:
        geo_task.cancel()
        try:
            await geo_task
        except asyncio.CancelledError:
            pass

    if macro_feed is not None:
        await macro_feed.stop()
    if macro_task is not None:
        macro_task.cancel()
        try:
            await macro_task
        except asyncio.CancelledError:
            pass

    # Unsubscribe Level 2 feed if active
    level2_feed = components.get("level2_feed")
    if level2_feed is not None and level2_feed.active_symbol:
        await level2_feed.unsubscribe()

    # Stop simulation engine if running
    simulation_engine = components.get("simulation_engine")
    if simulation_engine is not None and simulation_engine.running:
        await simulation_engine.stop()

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

    # Close EDGAR client if present
    edgar_client = components.get("edgar_client")
    if edgar_client is not None:
        await edgar_client.close()

    # Disconnect IBKR if connected
    ibkr_manager = components.get("ibkr_manager")
    if ibkr_manager is not None and ibkr_manager.is_connected:
        await ibkr_manager.disconnect()

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
    financials = components.get("financials")
    simulation_engine = components.get("simulation_engine")
    learning_tracker = components.get("learning_tracker")
    level2_feed = components.get("level2_feed")
    options_feed = components.get("options_feed")

    broadcaster.add_client(ws)
    log.info("ws.connected", clients=broadcaster.client_count)

    try:
        from cortex.api.protocol import (
            MessageType, CortexMessage, decode_message, encode_message,
        )
        import orjson

        # ── Send immediate state snapshot on connect ──────────────────
        try:
            orchestrator = components["orchestrator"]
            status_broadcaster = components.get("status_broadcaster")

            # 1. Portfolio snapshot
            if status_broadcaster is not None:
                portfolio_msg = CortexMessage(
                    type=MessageType.PORTFOLIO_UPDATE,
                    payload=status_broadcaster.portfolio_state,
                )
                await ws.send_text(encode_message(portfolio_msg))

            # 2. Agent snapshots (so squadron view populates immediately)
            for agent in orchestrator.agents:
                agent_msg = CortexMessage(
                    type=MessageType.AGENT_UPDATE,
                    payload={
                        "agent_id": agent.agent_id,
                        "squadron": getattr(agent, "squadron", "unknown"),
                        "status": getattr(agent, "status", "active"),
                        "signal_count": getattr(agent, "signal_count", 0),
                        "error_count": getattr(agent, "error_count", 0),
                    },
                )
                await ws.send_text(encode_message(agent_msg))

            # 3. Scanner snapshot (so scanner view populates immediately)
            market_feed = components.get("market_feed")
            if market_feed is not None:
                for opp in market_feed.scanner_opportunities:
                    scanner_msg = CortexMessage(
                        type=MessageType.SCANNER_RESULT,
                        payload={
                            "id": opp["ticker"],
                            "ticker": opp["ticker"],
                            "composite_score": opp["score"],
                            "type": opp["type"],
                            "thesis": opp["thesis"],
                            "risk_reward": opp["risk_reward"],
                            "direction": opp["direction"],
                            "sector": opp.get("sector", "Unknown"),
                            "market": "US Stocks",
                            "market_cap": opp.get("market_cap", "Unknown"),
                            "short_interest": 0.0,
                            "ai_insight": f"High momentum score ({opp['score']}) with {opp['type'].lower()} pattern",
                        },
                    )
                    await ws.send_text(encode_message(scanner_msg))

            log.info("ws.initial_snapshot_sent", agents=len(orchestrator.agents))
        except WebSocketDisconnect:
            broadcaster.remove_client(ws)
            log.info("ws.disconnected_during_snapshot")
            return
        except Exception as e:
            log.error("ws.snapshot_error", error=str(e))

        while True:
            # Handle both text and binary WebSocket frames
            raw = await ws.receive()
            if raw.get("type") == "websocket.disconnect":
                break
            if raw.get("text"):
                data = orjson.loads(raw["text"])
            elif raw.get("bytes"):
                data = orjson.loads(raw["bytes"])
            else:
                continue

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
                    client_context = msg.payload.get("context") or {}
                    # Enrich with live platform data
                    enriched_ctx = _build_enriched_context(client_context, components)
                    log.info(
                        "ws.chat_message",
                        length=len(user_text),
                        conversation_id=conversation_id,
                        tab=enriched_ctx.get("current_tab", "?"),
                    )
                    # Stream Claude response chunks back to the client
                    try:
                        async for chunk in chat.stream_response(
                            user_message=user_text,
                            conversation_id=conversation_id,
                            context=enriched_ctx,
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

            elif msg.type == MessageType.CMD_FINANCIALS_LOOKUP:
                symbol = msg.payload.get("symbol", "")
                if financials is not None and symbol:
                    log.info("ws.financials_lookup", symbol=symbol)

                    async def _safe_financials_lookup(sym: str, websocket):
                        try:
                            await financials.lookup(sym, ws=websocket)
                        except Exception as e:
                            log.error("ws.financials_lookup_error", symbol=sym, error=str(e))
                            err_msg = CortexMessage(
                                type=MessageType.FINANCIALS_ERROR,
                                payload={"symbol": sym, "error": str(e)},
                            )
                            await websocket.send_text(encode_message(err_msg))

                    asyncio.create_task(_safe_financials_lookup(symbol, ws))
                elif symbol:
                    # No financials aggregator available — send error
                    log.warning("ws.financials_unavailable", symbol=symbol)
                    err_msg = CortexMessage(
                        type=MessageType.FINANCIALS_ERROR,
                        payload={"symbol": symbol, "error": "Financials service unavailable"},
                    )
                    await ws.send_text(encode_message(err_msg))

            elif msg.type == MessageType.CMD_CONNECT_IBKR:
                ibkr_manager = components.get("ibkr_manager")
                if ibkr_manager is not None:
                    try:
                        await ibkr_manager.connect()
                        # Reconcile positions per CLAUDE.md
                        await ibkr_manager._reconcile_positions()
                        positions = ibkr_manager._ib.positions() if ibkr_manager._ib else []
                        pos_count = len(positions) if positions else 0
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.ACTIVITY_EVENT,
                            payload={
                                "event_type": "ibkr_connected",
                                "message": f"IBKR connected. {pos_count} positions reconciled.",
                                "severity": "info",
                            },
                        )))
                    except Exception as e:
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.ACTIVITY_EVENT,
                            payload={
                                "event_type": "ibkr_error",
                                "message": f"IBKR connection failed: {e}",
                                "severity": "critical",
                            },
                        )))

            # ── Trade View commands ──────────────────────────────────
            elif msg.type == MessageType.CMD_SUBMIT_ORDER:
                # Order submission goes through TradePipeline per CLAUDE.md
                pipeline = components.get("pipeline")
                if pipeline is not None:
                    order_data = msg.payload
                    log.info("ws.submit_order", symbol=order_data.get("symbol"))
                    try:
                        result = await pipeline.submit_order(order_data)
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.ORDER_STATUS,
                            payload=result,
                        )))
                    except Exception as e:
                        log.error("ws.order_error", error=str(e))
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.ORDER_STATUS,
                            payload={"status": "rejected", "error": str(e)},
                        )))

            elif msg.type == MessageType.CMD_CANCEL_ORDER:
                pipeline = components.get("pipeline")
                if pipeline is not None:
                    order_id = msg.payload.get("order_id")
                    log.info("ws.cancel_order", order_id=order_id)
                    try:
                        result = await pipeline.cancel_order(order_id)
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.ORDER_STATUS,
                            payload=result,
                        )))
                    except Exception as e:
                        log.error("ws.cancel_error", error=str(e))

            elif msg.type == MessageType.CMD_SET_TRADING_MODE:
                mode = msg.payload.get("mode", "paper")
                log.info("ws.set_trading_mode", mode=mode)
                # Store trading mode in components for pipeline to reference
                components["trading_mode"] = mode
                await ws.send_text(encode_message(CortexMessage(
                    type=MessageType.ACTIVITY_EVENT,
                    payload={
                        "event_type": "trading_mode_changed",
                        "message": f"Trading mode set to {mode}",
                        "severity": "info",
                    },
                )))

            # ── Options commands ─────────────────────────────────────
            elif msg.type == MessageType.CMD_GET_OPTION_CHAIN:
                if options_feed is not None:
                    symbol = msg.payload.get("symbol", "")
                    expiration = msg.payload.get("expiration")
                    log.info("ws.get_option_chain", symbol=symbol, expiration=expiration)
                    try:
                        chain = await options_feed.get_chain(symbol, expiration=expiration)
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.OPTION_CHAIN_DATA,
                            payload=chain,
                        )))
                    except Exception as e:
                        log.error("ws.option_chain_error", error=str(e))

            elif msg.type == MessageType.CMD_CALCULATE_PROFIT:
                from cortex.calculators.options_pricing import (
                    profit_matrix as calc_profit_matrix,
                    OptionLeg,
                )
                log.info("ws.calculate_profit")
                try:
                    raw_legs = msg.payload.get("legs", [])
                    price_range = msg.payload.get("price_range", [80, 120])
                    sigma = msg.payload.get("volatility", 0.25)
                    r = msg.payload.get("risk_free_rate", 0.05)

                    legs = [
                        OptionLeg(
                            strike=leg["strike"],
                            option_type=leg["option_type"],
                            quantity=leg["quantity"],
                            premium=leg["premium"],
                            expiry_years=leg.get("expiry_years", 0.25),
                        )
                        for leg in raw_legs
                    ]

                    result = calc_profit_matrix(
                        legs=legs,
                        price_range=tuple(price_range),
                        sigma=sigma,
                        r=r,
                    )
                    await ws.send_text(encode_message(CortexMessage(
                        type=MessageType.PROFIT_CALCULATION,
                        payload=result,
                    )))
                except Exception as e:
                    log.error("ws.profit_calc_error", error=str(e))

            # ── Watchlist & Alert commands ────────────────────────────
            elif msg.type == MessageType.CMD_ADD_WATCHLIST:
                market_feed = components.get("market_feed")
                if market_feed is not None:
                    symbol = msg.payload.get("symbol", "").upper()
                    if symbol:
                        market_feed.add_ticker(symbol)
                        log.info("ws.watchlist_added", symbol=symbol)

            elif msg.type == MessageType.CMD_CREATE_ALERT:
                # Store alert in memory for now (future: persistent storage)
                alert = msg.payload
                log.info(
                    "ws.alert_created",
                    symbol=alert.get("symbol"),
                    condition=alert.get("condition"),
                )
                await ws.send_text(encode_message(CortexMessage(
                    type=MessageType.ACTIVITY_EVENT,
                    payload={
                        "event_type": "alert_created",
                        "message": f"Alert created for {alert.get('symbol', '?')}",
                        "severity": "info",
                    },
                )))

            # ── Simulation commands ──────────────────────────────────
            elif msg.type == MessageType.CMD_START_SIMULATION:
                if simulation_engine is not None:
                    capital = msg.payload.get("starting_capital", 100_000.0)
                    log.info("ws.start_simulation", capital=capital)
                    try:
                        await simulation_engine.start(starting_capital=capital)
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.SIMULATION_UPDATE,
                            payload=simulation_engine.stats,
                        )))
                    except Exception as e:
                        log.error("ws.simulation_start_error", error=str(e))
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.ACTIVITY_EVENT,
                            payload={
                                "event_type": "simulation_error",
                                "message": f"Simulation start failed: {e}",
                                "severity": "error",
                            },
                        )))

            elif msg.type == MessageType.CMD_STOP_SIMULATION:
                if simulation_engine is not None:
                    log.info("ws.stop_simulation")
                    try:
                        stats = await simulation_engine.stop()
                        # Broadcast learning insights on stop
                        if learning_tracker is not None:
                            await learning_tracker.broadcast_insights()
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.SIMULATION_UPDATE,
                            payload=stats,
                        )))
                    except Exception as e:
                        log.error("ws.simulation_stop_error", error=str(e))
                        await ws.send_text(encode_message(CortexMessage(
                            type=MessageType.ACTIVITY_EVENT,
                            payload={
                                "event_type": "simulation_error",
                                "message": f"Simulation stop failed: {e}",
                                "severity": "error",
                            },
                        )))

            else:
                log.debug("ws.unhandled_command", msg_type=msg.type)

    except WebSocketDisconnect:
        broadcaster.remove_client(ws)
        log.info("ws.disconnected", clients=broadcaster.client_count)
    except Exception:
        broadcaster.remove_client(ws)
        raise


def _build_enriched_context(client_context: dict, components: dict) -> dict:
    """Merge client-side UI context with live backend data for Claude's system prompt."""
    ctx = dict(client_context)

    # ── Portfolio state ──
    sb = components.get("status_broadcaster")
    if sb is not None:
        ctx["portfolio"] = sb.portfolio_state  # returns a copy

    # ── Scanner opportunities + market quotes ──
    mf = components.get("market_feed")
    if mf is not None:
        ctx["scanner_opportunities"] = mf.scanner_opportunities  # public property

        # Snapshot market quotes (returns a copy via last_quotes property)
        ctx["market_quotes"] = {
            t: {
                "price": q.get("price", 0),
                "change": q.get("change", 0),
                "change_pct": q.get("change_pct", 0),
            }
            for t, q in mf.last_quotes.items()
        }

    # ── Agent health ──
    orch = components.get("orchestrator")
    if orch is not None:
        agents = []
        for agent in list(orch.agents):  # snapshot list for iteration safety
            agents.append({
                "id": agent.agent_id,
                "squadron": getattr(agent, "squadron", "unknown"),
                "status": getattr(agent, "status", "active"),
                "signal_count": getattr(agent, "signal_count", 0),
                "error_count": getattr(agent, "error_count", 0),
            })
        ctx["agents"] = agents

    # ── Kill switch ──
    ks = components.get("kill_switch")
    if ks is not None:
        ctx["kill_switch"] = {
            "active": getattr(ks, "is_halted", False),
            "reason": getattr(ks, "_engaged_reason", None),
        }

    # ── Level 2 state ──
    l2 = components.get("level2_feed")
    if l2 is not None and l2.active_symbol:
        ctx["level2"] = l2.to_dict()

    # ── Options feed state ──
    of = components.get("options_feed")
    if of is not None:
        ctx["options_feed"] = of.to_dict()

    # ── Simulation state ──
    sim = components.get("simulation_engine")
    if sim is not None:
        ctx["simulation"] = sim.to_dict()

    lt = components.get("learning_tracker")
    if lt is not None:
        ctx["learning_tracker"] = lt.to_dict()

    return ctx


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
    from cortex.squadrons.golf.trade_historian import TradeHistorian
    from cortex.squadrons.golf.pattern_learner import PatternLearner
    from cortex.squadrons.golf.strategy_optimizer import StrategyOptimizer
    from cortex.squadrons.golf.regime_detector import RegimeDetector
    from cortex.squadrons.golf.performance_tracker import PerformanceTracker
    from cortex.squadrons.golf.drawdown_analyzer import DrawdownAnalyzer
    from cortex.squadrons.golf.sector_momentum import SectorMomentum
    from cortex.squadrons.golf.correlation_tracker import CorrelationTracker
    from cortex.squadrons.hotel.spread_analyzer import SpreadAnalyzer
    from cortex.squadrons.hotel.depth_reader import DepthReader
    from cortex.squadrons.hotel.tick_analyzer import TickAnalyzer
    from cortex.squadrons.hotel.price_level_mapper import PriceLevelMapper
    from cortex.squadrons.hotel.execution_optimizer import ExecutionOptimizer
    from cortex.squadrons.hotel.latency_monitor import LatencyMonitor
    from cortex.api.ws_broadcaster import WSBroadcaster
    from cortex.connectors.polygon.rest_client import PolygonRESTClient
    from cortex.feeds.market_data import MarketDataFeed
    from cortex.feeds.scanner_engine import ScannerEngine
    from cortex.intelligence.chat import CortexChat
    from cortex.intelligence.providers import build_router
    from cortex.feeds.status_broadcaster import StatusBroadcaster
    from cortex.connectors.geo.client import GeoEgressClient
    from cortex.feeds.geo_feed import GeoIntelligenceFeed
    from cortex.squadrons.india.maritime_analyst import MaritimeAnalyst
    from cortex.squadrons.india.geo_risk_mapper import GeoRiskMapper
    from cortex.connectors.macro.client import MacroEgressClient
    from cortex.feeds.macro_feed import MacroFeed
    from cortex.squadrons.juliett.rates_analyst import RatesAnalyst
    from cortex.connectors.ibkr.client import IBKRConnectionManager, IBKRConfig
    from cortex.connectors.ibkr.rate_limiter import IBKRRateLimiter
    from cortex.connectors.sec.edgar_client import EDGARClient
    from cortex.feeds.financials import FinancialsAggregator
    from cortex.simulation.engine import SimulationEngine
    from cortex.simulation.learning_tracker import LearningTracker
    from cortex.feeds.level2 import Level2Feed
    from cortex.feeds.options import OptionsFeed
    from cortex.calculators.options_pricing import (
        black_scholes,
        greeks as compute_greeks,
        implied_volatility,
        profit_matrix,
        OptionLeg,
    )

    bus = SignalBus()
    autonomy = AutonomyDial()

    # Local-first LLM router (local Ollama/MLX -> Claude -> Gemini, offline_only aware).
    # Built early so squadrons (e.g. DELTA news sentiment) can use it.
    llm_router = build_router(config)

    # Rust-accelerated technical scanner engine.
    scanner_engine = ScannerEngine()

    # ECHO squadron
    kill_switch = KillSwitchCommander(bus=bus)
    drawdown_shield = DrawdownShield()
    guardian = RiskGuardian(
        bus=bus,
        kill_switch_check=lambda: kill_switch.is_halted,
        pre_trade=PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50),
        position_sizer=PositionSizer(max_position_pct=5.0, max_single_loss_usd=500.0),
        drawdown_shield=drawdown_shield,
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
    news_catalyst = NewsCatalyst(bus=bus, llm_router=llm_router)
    orchestrator.register_agent(news_catalyst)

    # GOLF squadron — Adaptive Learning
    trade_historian = TradeHistorian(bus=bus)
    orchestrator.register_agent(trade_historian)

    pattern_learner = PatternLearner(bus=bus, trade_historian=trade_historian)
    orchestrator.register_agent(pattern_learner)

    strategy_optimizer = StrategyOptimizer(bus=bus)
    orchestrator.register_agent(strategy_optimizer)

    regime_detector = RegimeDetector(bus=bus)
    orchestrator.register_agent(regime_detector)

    performance_tracker = PerformanceTracker(bus=bus)
    orchestrator.register_agent(performance_tracker)

    golf_drawdown_analyzer = DrawdownAnalyzer(bus=bus)
    orchestrator.register_agent(golf_drawdown_analyzer)

    sector_momentum = SectorMomentum(bus=bus)
    orchestrator.register_agent(sector_momentum)

    correlation_tracker = CorrelationTracker(bus=bus)
    orchestrator.register_agent(correlation_tracker)

    # HOTEL squadron — Market Microstructure
    spread_analyzer = SpreadAnalyzer(bus=bus)
    orchestrator.register_agent(spread_analyzer)

    depth_reader = DepthReader(bus=bus)
    orchestrator.register_agent(depth_reader)

    tick_analyzer = TickAnalyzer(bus=bus)
    orchestrator.register_agent(tick_analyzer)

    price_level_mapper = PriceLevelMapper(bus=bus)
    orchestrator.register_agent(price_level_mapper)

    execution_optimizer = ExecutionOptimizer(bus=bus)
    orchestrator.register_agent(execution_optimizer)

    latency_monitor = LatencyMonitor(bus=bus)
    orchestrator.register_agent(latency_monitor)

    # INDIA squadron — Geospatial alt-data / physical alpha
    maritime_analyst = MaritimeAnalyst(bus=bus)
    orchestrator.register_agent(maritime_analyst)

    geo_risk_mapper = GeoRiskMapper(bus=bus)
    orchestrator.register_agent(geo_risk_mapper)

    # JULIETT squadron — Macro / fixed income
    rates_analyst = RatesAnalyst(bus=bus)
    orchestrator.register_agent(rates_analyst)

    # WebSocket broadcaster
    broadcaster = WSBroadcaster(bus=bus)

    # Polygon REST client
    polygon_client = PolygonRESTClient(api_key=config.polygon_api_key)

    # Claude chat interface
    chat = CortexChat(
        api_key=config.anthropic_api_key,
        model=config.claude_model,
        bus=bus,
    )

    # SEC EDGAR client (free, no API key needed)
    edgar_client = EDGARClient()

    # Financials aggregator (combines Polygon, EDGAR, and AI)
    financials = FinancialsAggregator(
        polygon_client=polygon_client,
        edgar_client=edgar_client,
        chat=chat,
    )

    # Periodic status broadcaster (with drawdown_shield for NAV updates per CLAUDE.md)
    status_broadcaster = StatusBroadcaster(
        broadcaster=broadcaster,
        orchestrator=orchestrator,
        bus=bus,
        drawdown_shield=drawdown_shield,
        interval=5.0,
    )

    # Market data feed (wired to status_broadcaster for simulated NAV until IBKR connects)
    market_feed = MarketDataFeed(
        polygon_client=polygon_client,
        broadcaster=broadcaster,
        bus=bus,
        status_broadcaster=status_broadcaster,
    )

    # Geo-intelligence feed (maritime AIS + seismic through the hardened Rust egress)
    geo_client = GeoEgressClient()
    geo_feed = GeoIntelligenceFeed(
        geo_client=geo_client,
        broadcaster=broadcaster,
        bus=bus,
        poll_interval=config.geo_poll_interval,
        enabled=config.geo_enabled,
    )

    # Macro / fixed-income feed (Treasury rates through the same hardened egress)
    macro_client = MacroEgressClient(fred_api_key=config.fred_api_key)
    macro_feed = MacroFeed(
        macro_client=macro_client,
        broadcaster=broadcaster,
        bus=bus,
        poll_interval=config.macro_poll_interval,
        enabled=config.macro_enabled,
    )

    # IBKR (optional — only if TWS/Gateway is running)
    ibkr_rate_limiter = IBKRRateLimiter()

    # Don't auto-connect IBKR — it requires TWS/Gateway to be running
    # Instead, create it but only connect on demand or when TWS is detected
    ibkr_config = IBKRConfig(
        host=config.ibkr_host,
        port=config.ibkr_port,
        client_id=config.ibkr_client_id,
    )
    ibkr_manager = IBKRConnectionManager(config=ibkr_config, rate_limiter=ibkr_rate_limiter)

    # Level 2 data feed (order book depth from IBKR)
    level2_feed = Level2Feed(
        ibkr_manager=ibkr_manager,
        broadcaster=broadcaster,
        rate_limiter=ibkr_rate_limiter,
    )

    # Options data feed (chain data from Polygon / IBKR)
    options_feed = OptionsFeed(
        polygon_client=polygon_client,
        ibkr_manager=ibkr_manager,
        broadcaster=broadcaster,
        rate_limiter=ibkr_rate_limiter,
    )

    # Simulation engine (paper trading)
    simulation_engine = SimulationEngine(bus=bus, broadcaster=broadcaster)
    learning_tracker = LearningTracker(analysis_interval=50, broadcaster=broadcaster)

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
        "ibkr_rate_limiter": ibkr_rate_limiter,
        "ibkr_manager": ibkr_manager,
        "drawdown_shield": drawdown_shield,
        "edgar_client": edgar_client,
        "financials": financials,
        "simulation_engine": simulation_engine,
        "learning_tracker": learning_tracker,
        "level2_feed": level2_feed,
        "options_feed": options_feed,
        "geo_client": geo_client,
        "geo_feed": geo_feed,
        "maritime_analyst": maritime_analyst,
        "geo_risk_mapper": geo_risk_mapper,
        "llm_router": llm_router,
        "scanner_engine": scanner_engine,
        "macro_client": macro_client,
        "macro_feed": macro_feed,
        "rates_analyst": rates_analyst,
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("cortex.main:app", host="127.0.0.1", port=8765, reload=True)
