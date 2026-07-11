#!/bin/sh
# Supervisor for supergateway + chrome-devtools-mcp.
#
# Layer 1 (main loop): wait for Chrome, then run supergateway. If it exits,
#   restart after a short backoff. Container-level `restart: unless-stopped`
#   handles the case where this script itself dies.
#
# Layer 2 (chrome watcher): a cheap heartbeat every WATCH_INTERVAL (5s). When a
#   heartbeat misses, it runs a tight confirmation burst — WATCH_CONFIRM_CHECKS
#   (2) re-checks WATCH_CONFIRM_INTERVAL (1s) apart — and only kills supergateway
#   if every confirm check also fails, so the main loop recycles it. The burst
#   debounces transient blips (a single missed heartbeat never recycles) while
#   still confirming a real outage within ~2s. Needed because supergateway in
#   --stateful mode keeps its HTTP listener alive even when the inner stdio child
#   (chrome-devtools-mcp) becomes useless after Chrome restarts — a healthcheck
#   on /healthz wouldn't catch that.
set -u

PORT="${PORT:-8765}"
CHROME_DEBUG_PORT="${CHROME_DEBUG_PORT:-9222}"
# Cheap heartbeat cadence (seconds) for the chrome watcher.
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"
# On a missed heartbeat, how many rapid confirm re-checks to run, and how far
# apart (seconds). Recycle only if the heartbeat AND every confirm check fail.
WATCH_CONFIRM_CHECKS="${WATCH_CONFIRM_CHECKS:-2}"
WATCH_CONFIRM_INTERVAL="${WATCH_CONFIRM_INTERVAL:-1}"
# How often to re-log "waiting for Chrome..." while it stays down (seconds).
WAIT_LOG_INTERVAL="${WAIT_LOG_INTERVAL:-60}"
# Poll period of the main wait loop (seconds).
WAIT_POLL_INTERVAL="${WAIT_POLL_INTERVAL:-5}"

resolve_host_ip() {
  getent ahosts host.docker.internal | awk '$1 ~ /\./ { print $1; exit }'
}

chrome_ok() {
  wget -qO- --timeout=3 --tries=1 "http://${HOST_IP}:${CHROME_DEBUG_PORT}/json/version" >/dev/null 2>&1
}

log() { printf '[entrypoint] %s\n' "$*"; }

HOST_IP="$(resolve_host_ip)"
if [ -z "$HOST_IP" ]; then
  log "FATAL: could not resolve host.docker.internal"
  exit 1
fi
log "host.docker.internal -> ${HOST_IP}, target Chrome :${CHROME_DEBUG_PORT}, gateway :${PORT}"

# Watcher: recycle supergateway when Chrome flaps.
# Cheap heartbeat every WATCH_INTERVAL; a missed heartbeat triggers a robust
# confirmation burst before acting. Skips silently if supergateway isn't
# running — the main loop's wait phase already covers that case.
(
  while true; do
    sleep "$WATCH_INTERVAL"
    chrome_ok && continue

    # Missed heartbeat — run the robust confirmation burst. Any success means
    # it was a transient blip, so bail out and resume the cheap cadence.
    down=1
    i=0
    while [ "$i" -lt "$WATCH_CONFIRM_CHECKS" ]; do
      sleep "$WATCH_CONFIRM_INTERVAL"
      if chrome_ok; then
        down=0
        break
      fi
      i=$((i + 1))
    done
    [ "$down" -eq 1 ] || continue

    if pgrep -f 'supergateway' >/dev/null 2>&1; then
      log "watcher: Chrome unreachable (heartbeat + ${WATCH_CONFIRM_CHECKS} confirm checks failed), recycling supergateway"
      pkill -TERM -f 'supergateway' 2>/dev/null || true
    fi
  done
) &

# Main loop.
while true; do
  waited=0
  logged_at=-1
  while ! chrome_ok; do
    if [ "$logged_at" -lt 0 ] || [ "$((waited - logged_at))" -ge "$WAIT_LOG_INTERVAL" ]; then
      log "waiting for Chrome at http://${HOST_IP}:${CHROME_DEBUG_PORT}..."
      logged_at="$waited"
    fi
    sleep "$WAIT_POLL_INTERVAL"
    waited=$((waited + WAIT_POLL_INTERVAL))
  done
  log "Chrome reachable; starting supergateway"
  supergateway \
    --stdio "chrome-devtools-mcp --browserUrl http://${HOST_IP}:${CHROME_DEBUG_PORT} --acceptInsecureCerts" \
    --outputTransport streamableHttp \
    --stateful \
    --port "$PORT" \
    --healthEndpoint /healthz \
    --logLevel info \
    || true
  log "supergateway exited; restarting in 2s"
  sleep 2
done
