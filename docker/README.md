# Docker (stubs — finalized in M8)

Docker is **not installed** in the current dev environment; these files are
starting points for the M8 hardening/ops milestone, not yet validated.

They assume a **headless Linux export** of the project exists (the export presets
are an M8 deliverable, ADR-0002). The exported server/bot binary is copied into a
slim base image. Running from source inside Docker (shipping the whole engine +
project) is also possible but heavier; M8 will pick one and document it.

- `Dockerfile.server` — one dedicated server instance.
- `Dockerfile.bots`   — bot driver; `BOT_COUNT` bots per container.
- `compose.stress.yml` — 1 server + bot containers to reach 128 players.

Target end state (M8 gate):

```
docker compose -f docker/compose.stress.yml up
```
