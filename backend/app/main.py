from fastapi import FastAPI
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings, get_settings
from app.db import init_db, make_engine, make_sessionmaker


def create_app(settings: Settings | None = None,
               sessionmaker: async_sessionmaker[AsyncSession] | None = None) -> FastAPI:
    settings = settings or get_settings()
    app = FastAPI(title="Blockfire Stats API")
    app.state.settings = settings

    if sessionmaker is None:
        engine = make_engine(settings.database_url)
        app.state.engine = engine
        sessionmaker = make_sessionmaker(engine)

        @app.on_event("startup")
        async def _startup() -> None:
            await init_db(engine)

    app.state.sessionmaker = sessionmaker

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"status": "ok"}

    from app.routes import register_ingest_routes  # local import avoids cycle
    from app.steam_openid import register_auth_routes
    from app.web import register_web_routes
    from app.web_api import register_api_routes
    from app.admin_api import register_admin_api_routes
    register_ingest_routes(app)
    register_api_routes(app)
    register_auth_routes(app)
    register_web_routes(app)
    register_admin_api_routes(app)
    return app


app = create_app()
