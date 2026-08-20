#!/usr/bin/env bash
# Runs the browser checks the way CI runs them: on Linux, against the three
# engines, with the demo actually serving.
#
# Meant to be run inside the image built from docker/Dockerfile — see
# docker/README.md — but it will run anywhere the same tools exist.
set -euo pipefail

cd "$(dirname "$0")/../demo"

export PORT="${PORT:-4321}"

browsers=("$@")
if [ ${#browsers[@]} -eq 0 ]; then
  browsers=(chromium firefox webkit)
fi

echo "==> dependencies"
mix deps.get >/dev/null
npm ci --no-audit --no-fund >/dev/null

echo "==> assets"
mix assets.setup >/dev/null
mix assets.build >/dev/null

echo "==> demo"
mix phx.server >/tmp/demo.log 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -sf -o /dev/null "http://localhost:${PORT}/" && break
  sleep 1
done

if ! curl -sf -o /dev/null "http://localhost:${PORT}/"; then
  echo "the demo never came up:"
  tail -20 /tmp/demo.log
  exit 1
fi

failed=0

for browser in "${browsers[@]}"; do
  echo "==> $browser"
  BROWSER="$browser" BASE_URL="http://localhost:${PORT}" node test/browser/editor.mjs || failed=1
done

exit "$failed"
