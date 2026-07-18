# Blockfire — agent quick-start

**The full working agreement is `docs/AGENTS.md` — read it.** It is NOT auto-loaded (it lives under `docs/`), so this root file surfaces the rules the harness *does* auto-load. Highlights below; `docs/AGENTS.md` is authoritative.

## Explore with graphify — don't grep/read files blind

- **Any "where does X happen / what calls Y / what extends Z / how does subsystem Z work" question is a graphify query first**, not a manual file hunt:
  `python3 -m graphify query "<question>"` (or `/graphify query "<question>"` in Claude Code).
  Also: `graphify path "A" "B"`, `graphify explain "X"`, `graphify affected "X"`.
- **The graph already exists** at `graphify-out/graph.json` — query it directly. Do not rebuild it to answer a read-only question.
- Manual file reading is the **fallback**: open files to read/edit the specific lines a query pointed you to.
- Pass this same rule to any subagent you dispatch to explore code.

## Keeping the graph fresh (cheap by design)

- **Code auto-refreshes.** A `post-commit` hook re-runs AST extraction (~5s, no LLM) after every commit. You do nothing for code changes. After a fresh clone, reinstall it once: `python3 -m graphify hook install`.
- **Docs are deliberate.** On milestone close / significant doc changes, run `/graphify --update` **scoped and batched**: active docs only, exclude `docs/archive/**` and `docs/gate-evidence/**`, ≤2–3 extraction subagents at a time. **Never fan out the whole doc corpus at once** — a full stale-corpus rebuild can burn a whole session's token budget.

## Everything else — see `docs/AGENTS.md`

Superpowers skills (TDD, brainstorming, subagent-driven-development), one-owner-per-task, ADRs, hard gates, determinism/authority discipline, the game2 fleet gate, BattleBit balance, and **§11 "land your work" (commit → merge to master → push)**.
