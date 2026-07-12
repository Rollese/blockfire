# Search-indexing agent brief — get blockfire.cc into Google + Bing

Hand this to a separate agent to register the domain with Google Search Console
and Bing Webmaster Tools and get it crawled/indexed. It should **make the
changes and self-verify** using credentials the owner provides, falling back to
exact manual steps only where automation isn't possible.

Status (2026-07-12): the Cloudflare WAF now **allows verified search crawlers**
(Googlebot/Bingbot → `200`), so the indexing path is clear. A first attempt was
paused on Google-side rate-limiting.

## What exists already
- **Marketing site:** https://blockfire.cc  (live, valid TLS)
- **Stats site:** https://stats.blockfire.cc (live, valid TLS)
- **Sitemap:** https://blockfire.cc/sitemap.xml  (4 URLs: `/`, `/contact/`,
  `/privacy/`, `/terms/`)
- **robots.txt:** https://blockfire.cc/robots.txt — `Allow: /`, references the
  sitemap. The 404 page is `noindex`; everything else is indexable.
- **DNS** is on **Cloudflare** (zone id `0804e36218b5e084483ec6d1a3200c77`).
  A scoped token that can create/edit DNS records for `blockfire.cc`
  (`Zone.DNS:Edit`) lives on host **game2** at `~/.cf_blockfire_token` — use it
  for the DNS-TXT verification steps.

## Confirm crawlability first
```
curl -sI -A "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" https://blockfire.cc/
curl -sI -A "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)" https://blockfire.cc/
```
Expect `HTTP/2 200`. A `403` + `cf-mitigated: challenge` means the crawler is
being blocked — stop and get the WAF rule fixed before proceeding.

## Part A — Google Search Console
1. Create a **Domain property** (`blockfire.cc`) — covers apex + `www` + `stats`
   + both protocols.
2. Verify via **DNS TXT** (`google-site-verification=…`) added with the
   Cloudflare token, then trigger verification.
3. Submit `https://blockfire.cc/sitemap.xml`; confirm **0 errors** and all 4
   URLs discovered.
4. Run URL Inspection on `/` (and the subpages); request indexing; report status.

## Part B — Bing Webmaster Tools
1. Fastest: **Import from GSC** once Part A is verified (copies site + sitemaps).
2. Otherwise add the site manually and verify via **DNS TXT/CNAME** (Cloudflare
   token), not the meta-tag/XML-file methods.
3. Confirm the sitemap is submitted with 0 errors; run "Test URL live" on `/`.
4. Note: Bing WMT also feeds DuckDuckGo/Yahoo.

## Credentials — ask the owner for the RIGHT kind (not a plain "API key")
- **Cloudflare API token** — already on game2 (`~/.cf_blockfire_token`) for DNS
  verification (both engines).
- **Google Search Console API** — needs a **Google Cloud service-account JSON
  key** with the *Search Console API* (and optionally *Indexing API*) enabled,
  and that service account added as an **Owner/Full user** on the property.
  Ask the owner to add the service-account email, or to create the key.
- **Bing Webmaster API** — Bing issues a real **API key** (Settings → API
  Access) that can submit sitemaps/URLs programmatically; ask the owner to
  generate and paste it to automate the Bing side.

Start by (a) confirming Googlebot/Bingbot aren't challenged and (b) telling the
owner which credentials you need. Then do the work and self-verify both engines.
