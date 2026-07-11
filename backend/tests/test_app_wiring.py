"""Integration wiring: all four route groups (ingest, api, web, auth) mounted;
public surface must not 500 on a fresh empty DB."""


async def test_healthz(client):
    r = await client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


async def test_index_renders_empty(client):
    r = await client.get("/")
    assert r.status_code == 200
    # empty leaderboard renders the "no players" state
    assert "No players yet." in r.text


async def test_api_leaderboard_empty(client):
    r = await client.get("/api/leaderboard")
    assert r.status_code == 200
    assert r.json() == {"players": []}


async def test_login_redirects(client):
    r = await client.get("/login", follow_redirects=False)
    assert r.status_code == 302


async def test_web_profile_missing_404(client):
    r = await client.get("/players/name:nobody")
    assert r.status_code == 404


async def test_api_profile_missing_404(client):
    r = await client.get("/api/players/name:nobody")
    assert r.status_code == 404


async def test_index_shows_sign_in_when_logged_out(client):
    r = await client.get("/")
    assert r.status_code == 200
    assert "Sign in through Steam" in r.text
