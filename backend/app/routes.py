from fastapi import Depends, FastAPI, Request, Response

from app.auth import require_ingest_token
from app.ingest import ingest_event_batch, ingest_match_report
from app.schemas import EventBatchIn, MatchReportIn


def register_ingest_routes(app: FastAPI) -> None:
    @app.post("/ingest/events", status_code=202,
              dependencies=[Depends(require_ingest_token)])
    async def ingest_events(batch: EventBatchIn, request: Request) -> Response:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_event_batch(session, batch)
        return Response(status_code=202)

    @app.post("/ingest/match", status_code=202,
              dependencies=[Depends(require_ingest_token)])
    async def ingest_match(report: MatchReportIn, request: Request) -> Response:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_match_report(session, report)
        return Response(status_code=202)
