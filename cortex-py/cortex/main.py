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
