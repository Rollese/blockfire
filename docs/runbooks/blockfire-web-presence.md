# Runbook — blockfire.cc web presence

Operational reference for the blockfire.cc rollout (marketing site + M20 stats +
email). Companion to the plan
`docs/superpowers/plans/2026-07-12-blockfire-web-presence.md` and spec
`docs/superpowers/specs/2026-07-12-blockfire-web-presence-design.md`.

**No secrets in this file.** Tokens/passwords live only in `~/.cf_blockfire_token`
(game2), `backend/.env` (untracked), and the owner's password manager.

## Concrete values

| Key | Value |
|---|---|
| Cloudflare zone id | `0804e36218b5e084483ec6d1a3200c77` |
| Origin (home) IP — apex/www/stats | `178.174.157.185` (Cloudflare-proxied) |
| VPS IP (`rapid.rolandot.com`) | `188.68.247.11` |
| Mail host (blockfire.cc MX target) | `mail.rolandot.com` (existing, valid rDNS+cert) |
| Dev upstream host | game2 `192.168.1.166` |
| Static site port (game2) | `8080` |
| M20 stats port (game2) | `8000` |
| DMS config dir (VPS) | `/srv/docker-mailserver` |
| Admin SteamID64 | `76561197991773727` |

## Preflight (Task 0.1) — edge Caddy ACME token must cover blockfire.cc

The edge Caddyfile issues certs via `acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}`.
That container-env token is **separate** from `~/.cf_blockfire_token` and must be able
to write DNS for blockfire.cc, or the cert won't issue. Check on unraid:

```bash
CADDY_TOKEN=$(docker exec <caddy_container> printenv CLOUDFLARE_API_TOKEN)
curl -s -H "Authorization: Bearer $CADDY_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=blockfire.cc" | grep -o '"count":[0-9]*'
```

`"count":1` ⇒ good. `"count":0` ⇒ add blockfire.cc to that token (dashboard → API
Tokens → edit → Zone Resources), no Caddy restart needed.

- **Result:** ✅ `count:1` (owner-confirmed 2026-07-12) — edge Caddy token can issue for blockfire.cc.

## DNS records (Cloudflare)

Apex/www/stats are **A records, proxied (orange)**. Email records are **DNS-only
(grey)**. All created via `~/.cf_blockfire_token` (scoped `Zone.DNS:Edit` for
blockfire.cc).

| Name | Type | Value | Proxy | Purpose | Status |
|---|---|---|---|---|---|
| `blockfire.cc` | A | `178.174.157.185` | proxied | marketing site | ✅ created |
| `www.blockfire.cc` | A | `178.174.157.185` | proxied | www→apex redirect | ✅ created |
| `stats.blockfire.cc` | A | `178.174.157.185` | proxied | M20 stats | ✅ created |
| `blockfire.cc` | MX | `mail.rolandot.com` (pri 10) | DNS-only | email | ✅ created |
| `blockfire.cc` | TXT | `v=spf1 mx -all` | DNS-only | SPF | ✅ created |
| `mail._domainkey.blockfire.cc` | TXT | `v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A...AQAB` (selector `mail`, OpenDKIM 2048-bit) | DNS-only | DKIM | ✅ created |
| `_dmarc.blockfire.cc` | TXT | `v=DMARC1; p=quarantine; rua=mailto:postmaster@blockfire.cc; adkim=s; aspf=s` | DNS-only | DMARC | ✅ created |

**Email account:** `hello@blockfire.cc` (mailbox) + catch-all alias `@blockfire.cc → hello@blockfire.cc` on the VPS docker-mailserver. Password in `/home/roland/.bf_mail_hello_pw` (game2, chmod 600) — move to the owner's password manager. DKIM selector `mail`, key at `/srv/docker-mailserver/docker-data/dms/config/opendkim/keys/blockfire.cc/mail.txt`.

## Edge Caddy blocks (owner applies to the live unraid Caddyfile)

Append these to the existing Caddyfile. They reuse the existing `(cloudflare)`
snippet and match the orange-proxied pattern used by the other public sites. Dev
upstreams point at game2; see **Prod cutover** to re-point later.

```caddy
blockfire.cc {
	import cloudflare
	handle @cloudflare {
		reverse_proxy http://192.168.1.166:8080 {
			header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
		}
	}
	# Deny requests from non-Cloudflare IPs
	handle {
		respond "Access Denied" 403
	}
}

www.blockfire.cc {
	redir https://blockfire.cc{uri}
}

stats.blockfire.cc {
	import cloudflare
	handle @cloudflare {
		reverse_proxy http://192.168.1.166:8000 {
			header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
		}
	}
	# Deny requests from non-Cloudflare IPs
	handle {
		respond "Access Denied" 403
	}
}
```

> **Caddyfile gotcha:** a block's opening `{` must be followed by a newline — the
> one-liner `handle { respond "Access Denied" 403 }` fails to adapt. Keep `handle`
> blocks multi-line as above (matches the other sites in this Caddyfile).

Validate + reload (no restart if reload works):

```bash
docker exec <caddy_container> caddy validate --config /etc/caddy/Caddyfile
docker exec <caddy_container> caddy reload  --config /etc/caddy/Caddyfile
```

Expected: `Valid configuration`; reload exits 0. Caddy fetches the cert via DNS-01 on
first request (needs Preflight green).

**Verify end-to-end after reload:**

```bash
curl -sSI https://blockfire.cc | head -3          # HTTP/2 200, valid cert, placeholder
curl -sS  https://stats.blockfire.cc/healthz      # {"status":"ok"} (once Phase 2 deployed)
curl -sI  https://www.blockfire.cc/ | grep -i location   # -> https://blockfire.cc
```

- 502 ⇒ edge can't reach the game2 upstream (container down / firewall).
- TLS error ⇒ cert didn't issue (recheck Preflight token scope).

## Prod cutover (Phase 5 — when stacks move to unraid)

_To be finalized in Phase 5._ Outline: run `backend/` + `web/` compose on unraid;
change the two `reverse_proxy` upstreams above from `192.168.1.166:{8000,8080}` to the
unraid-local addresses; `caddy validate` + `reload`; re-verify the Phase 1–3 checks.
DNS and email records do **not** change on cutover.
