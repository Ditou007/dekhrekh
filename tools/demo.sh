#!/usr/bin/env bash
# Runs the built panel (or, with `cli ...`, the CLI) against made-up sessions, usage and a fake
# server, for screenshots.
# Nothing real is read except memory, and CI for two public repos. Run ./build.sh first.
# Quit the installed Dekhrekh before running, or you will see two panels. Ctrl-C to stop.
set -euo pipefail
cd "$(dirname "$0")/.."

D="$(mktemp -d)"
PORT=8765
PIDS=()
cleanup() { { kill "${PIDS[@]}"; wait; } 2>/dev/null || true; rm -rf "$D"; }
trap cleanup EXIT

mkdir -p "$D/claude/sessions" "$D/state/statusline" "$D/state/notify" "$D/state/claims" "$D/server"
now=$(date +%s)

# name | folder | status | context left % | claim
sessions=(
  "Checkout flow: payment retries|~/code/shop-api|waiting|61|shop-api: fix/payment-retry - retry and idempotency keys"
  "Search ranking experiment|~/code/search|busy|38|search: exp/bm25-tuning - ranking weights"
  "Release notes for v2.4|~/code/web|busy|17|"
  "Flaky e2e on CI|~/code/web|idle|72|web: ci/e2e-retries - Playwright retries"
)
i=0
for row in "${sessions[@]}"; do
  IFS='|' read -r name folder status ctx claim <<< "$row"
  sleep 3600 & PIDS+=($!)
  sid="demo-$i"
  cat > "$D/claude/sessions/$!.json" <<EOF
{"pid": $!, "sessionId": "$sid", "name": "$name", "cwd": "${folder/#\~/$HOME}", "status": "$status",
 "kind": "interactive", "statusUpdatedAt": $(( (now - 60 * (i + 2)) * 1000 ))}
EOF
  cat > "$D/state/statusline/$sid.json" <<EOF
{"session_id": "$sid", "context_window": {"remaining_percentage": $ctx},
 "rate_limits": {"five_hour": {"used_percentage": 46, "resets_at": $(( now + 2 * 3600 + 900 ))},
                 "seven_day": {"used_percentage": 58, "resets_at": $(( now + 3 * 86400 ))}},
 "widget_profile": "work", "widget_ts": $now}
EOF
  [ -n "$claim" ] && echo "{\"note\": \"$claim\", \"cwd\": \"${folder/#\~/$HOME}\", \"ts\": $now}" > "$D/state/claims/$sid.json"
  [ "$status" = waiting ] && echo "{\"message\": \"Claude needs your permission to use Bash\", \"ts\": $now}" > "$D/state/notify/$sid.json"
  i=$((i + 1))
done

cat > "$D/server/status" <<EOF
{"node": {"mem_used_gb": 11.2, "mem_total_gb": 32, "load1": 2.1, "disk_pct": 41, "uptime_h": 312},
 "cores": 8, "temp_c": 61, "containers": {"down": []},
 "guests": [
   {"id": 101, "name": "ci-runner", "type": "qemu", "status": "running", "mem_gb": 6.1, "maxmem_gb": 12, "host_cpu_pct": 18},
   {"id": 102, "name": "postgres", "type": "lxc", "status": "running", "mem_gb": 2.4, "maxmem_gb": 4, "host_cpu_pct": 3},
   {"id": 103, "name": "media", "type": "lxc", "status": "running", "mem_gb": 1.2, "maxmem_gb": 4, "host_cpu_pct": 1}
 ]}
EOF
(cd "$D/server" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) & PIDS+=($!)

cat > "$D/config.json" <<EOF
{"stateDir": "$D/state",
 "profiles": [{"name": "work", "title": "Work", "claudeDir": "$D/claude"}],
 "repos": [{"label": "gh cli", "repo": "cli/cli"}, {"label": "homebrew", "repo": "Homebrew/brew"}],
 "server": {"title": "Home server", "url": "http://127.0.0.1:$PORT/status", "cores": 8}}
EOF

# `tools/demo.sh cli <args>` runs the CLI against the demo instead of opening the panel.
if [ "${1:-}" = cli ]; then
  shift
  DEKHREKH_CONFIG="$D/config.json" build/dekhrekh "$@"
  exit
fi

echo "demo running from $D (Ctrl-C to stop)"
DEKHREKH_CONFIG="$D/config.json" build/Dekhrekh.app/Contents/MacOS/Dekhrekh
