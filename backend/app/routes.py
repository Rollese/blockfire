from fastapi import Depends, FastAPI, Request, Response

from app.auth import require_ingest_token, require_valid_signature
from app.ingest import ingest_event_batch, ingest_match_report
from app.schemas import EventBatchIn, MatchReportIn


def register_ingest_routes(app: FastAPI) -> None:
    @app.post("/ingest/events", status_code=202,
              dependencies=[Depends(require_ingest_token),
                            Depends(require_valid_signature)])
    async def ingest_events(batch: EventBatchIn, request: Request) -> Response:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_event_batch(session, batch)
        return Response(status_code=202)

    @app.post("/ingest/match", status_code=202,
              dependencies=[Depends(require_ingest_token),
                            Depends(require_valid_signature)])
    async def ingest_match(report: MatchReportIn, request: Request) -> Response:
        trusted = getattr(request.state, "ingest_trusted", False)
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_match_report(session, report, trusted=trusted)
        return Response(status_code=202)
