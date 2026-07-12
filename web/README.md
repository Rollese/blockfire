# Blockfire marketing site (static)

Plain static HTML/CSS served by `nginx:alpine`. No build step.

## Run (dev, game2)
    cd web && docker compose up -d --build
    curl -sI localhost:8080        # 200 OK

The unraid edge Caddy reverse-proxies blockfire.cc -> game2:8080 (see
docs/runbooks/blockfire-web-presence.md). Edit files under site/ and they are
served live (read-only bind mount).
