#!/bin/sh
# Runs the Blockfire project (server or bot fleet) under headless Godot.
# The role + flags come from the container `command` (e.g. `-- --server` or `-- --bots ...`).
set -e

# Optional startup delay so the bot fleet waits for the server to be listening before it
# connects (ENet is UDP, so there's no easy port-readiness probe — a short wait is simplest).
if [ -n "${BOOT_DELAY:-}" ]; then
	echo "[entrypoint] waiting ${BOOT_DELAY}s for server…"
	sleep "${BOOT_DELAY}"
fi

exec godot "$@"
