# Gate evidence

Small committed records of fleet-gate runs (AGENTS §6 "recorded evidence"). The raw server
logs are multi-MB and gitignored (`*.log`, they live on the gate host, e.g. game2's
`docker/srvlog-*.log`); each file here is the scraped verdict + numbers plus the sha256 of
the exact srvlog it summarizes, so the claim stays verifiable against the local log.

Written automatically by `docker/stress.sh` (via `gate_evidence` in `docker/_gate_lib.sh`)
on every PASS **and** FAIL. Commit the evidence file together with the change that closed
the gate. Older closed-milestone `run-*-gate.sh` scripts predate this and are not
retrofitted — their evidence is recorded in the milestone docs.

Format (one `key: value` per line):

```
gate: stress                # LABEL env of the run
date: 2026-07-02T15:09:31+02:00
host: game2
git: 64bb204                # HEAD when the gate ran
verdict: PASS
summary: winner=1 elapsed=145s peak_tick=16.48ms budget=33.3ms …
srvlog: srvlog-stress-20260702-150931.log
srvlog_sha256: <sha256 of that file>
```
