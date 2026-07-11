from fastapi import Depends, FastAPI, Request, Response

from app.auth import require_ingest_token
from app.ingest import ingest_event_batch
from app.schemas import EventBatchIn


def register_ingest_routes(app: FastAPI) -> None:
    @app.post("/ingest/events", status_code=202,
              dependencies=[Depends(require_ingest_token)])
    async def ingest_events(batch: EventBatchIn, request: Request) -> Response:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_event_batch(session, batch)
        return Response(status_code=202)
