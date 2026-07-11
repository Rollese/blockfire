import datetime as dt

import httpx
from sqlalchemy import select

from app.models import PlayerProfile
from app.steam_api import enrich_profiles, fetch_summaries

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)


def _summaries_response(steamids: list[str]) -> httpx.Response:
    players = [
        {
            "steamid": sid,
            "personaname": f"Persona{sid}",
            "avatarfull": f"https://avatars.example/{sid}.jpg",
        }
        for sid in steamids
    ]
    return httpx.Response(200, json={"response": {"players": players}})


def _profile(key: str, steam_id: int | None, name: str) -> PlayerProfile:
    return PlayerProfile(
        player_key=key, steam_id=steam_id, display_name=name,
        avatar_url=None, updated_at=NOW,
    )


async def test_fetch_summaries_parses_by_int_key():
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        ids = request.url.params["steamids"]
        seen.append(ids)
        return _summaries_response(ids.split(","))

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        out = await fetch_summaries(c, "KEY", [770, 771])

    assert out == {
        770: {"display_name": "Persona770",
              "avatar_url": "https://avatars.example/770.jpg"},
        771: {"display_name": "Persona771",
              "avatar_url": "https://avatars.example/771.jpg"},
    }
    assert len(seen) == 1


async def test_fetch_summaries_chunks_over_100():
    calls: list[list[str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        ids = request.url.params["steamids"].split(",")
        assert len(ids) <= 100
        calls.append(ids)
        return _summaries_response(ids)

    ids = list(range(1000, 1150))  # 150 ids
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        out = await fetch_summaries(c, "KEY", ids)

    assert len(calls) == 2
    assert len(out) == 150
    assert out[1000]["display_name"] == "Persona1000"


async def test_fetch_summaries_empty_no_call():
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("should not be called for empty input")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        out = await fetch_summaries(c, "KEY", [])
    assert out == {}


async def test_fetch_summaries_tolerates_missing_players():
    def handler(request: httpx.Request) -> httpx.Response:
        # Steam omits private/unknown accounts from the players array.
        return _summaries_response(["770"])

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        out = await fetch_summaries(c, "KEY", [770, 999])
    assert set(out) == {770}


async def test_enrich_profiles_updates_only_steam_rows(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        s.add(_profile("steam:770", 770, "OldName"))
        s.add(_profile("name:P2", None, "P2"))
        await s.commit()

    def handler(request: httpx.Request) -> httpx.Response:
        return _summaries_response(request.url.params["steamids"].split(","))

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        async with sm() as s:
            n = await enrich_profiles(s, "KEY", client=c)

    assert n == 1
    async with sm() as s:
        steam = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "steam:770"))).scalar_one()
        assert steam.display_name == "Persona770"
        assert steam.avatar_url == "https://avatars.example/770.jpg"
        name_only = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:P2"))).scalar_one()
        assert name_only.display_name == "P2"
        assert name_only.avatar_url is None


async def test_enrich_profiles_no_key_is_noop(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        s.add(_profile("steam:770", 770, "OldName"))
        await s.commit()

    async with sm() as s:
        n = await enrich_profiles(s, api_key=None)

    assert n == 0
    async with sm() as s:
        steam = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "steam:770"))).scalar_one()
        assert steam.display_name == "OldName"
        assert steam.avatar_url is None
