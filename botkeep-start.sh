#!/usr/bin/env bash
#
# OmniRoute — Botkeep.cloud runner (adapted from keirouter-mod's botkeep-start.sh)
#
# Why this exists (do NOT simplify without reading):
#   1. Botkeep's panel has NO env setter — every setting is self-contained here.
#   2. This repo's working tree is ~2 GB (1.3 GB of it .git) and a source build
#      (npm ci + next build) needs several GB on top. Botkeep gives 2 GB storage.
#      Building from source inside the container is impossible — it fails with
#      "no space left on device" (same failure KeiRouter hit).
#   3. Botkeep ZIP upload limit is 5 MB, so the runtime cannot be committed to
#      git either.
#      => Solution: the official npm tarball ships the PREBUILT Next.js bundle
#         (dist/server.js + dist/.build/next). Download it at start, install only
#         runtime deps, run. No git clone, no compile.
#   4. Botkeep assigns the port at runtime: read $SERVER_PORT (fallback $PORT),
#      bind 0.0.0.0 — loopback-only answers "This application is not responding".
#   5. DATA_DIR lives outside the app tree so restarts/redeploys never wipe the DB.
#
# Start command in the Botkeep panel:  bash botkeep-start.sh
# Runtime profile: Node 22 or 24 (Node 20 and below are rejected by OmniRoute).
#
set -euo pipefail

APP_PORT="${SERVER_PORT:-${PORT:-8080}}"
echo "==> OmniRoute on port $APP_PORT"

OMNIROUTE_VERSION="${OMNIROUTE_VERSION:-3.8.51}"
TARBALL_URL="https://registry.npmjs.org/omniroute/-/omniroute-${OMNIROUTE_VERSION}.tgz"

# Pinned homes so credentials + SQLite survive restarts and reinstalls.
DATA_DIR="${OMNIROUTE_DATA_DIR:-$HOME/data}"
APP_DIR="${OMNIROUTE_APP_DIR:-$HOME/app}"
mkdir -p "$DATA_DIR" "$APP_DIR"

info() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m OK\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m  !\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mERROR\033[0m %s\n" "$*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "node not found — use Botkeep's Node runtime profile (22 or 24)"
command -v npm  >/dev/null 2>&1 || die "npm not found — use Botkeep's Node runtime profile"
command -v curl >/dev/null 2>&1 || die "curl not found"

NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
if [ "$NODE_MAJOR" -lt 22 ]; then
  die "Node 22+ required (found $(node -v)). OmniRoute engines: >=22.22.2 <23 || >=24 <27"
fi

# ---------------------------------------------------------------------------
# 1. Prebuilt package (idempotent: skipped when the version stamp matches).
# ---------------------------------------------------------------------------
STAMP="$APP_DIR/.omniroute-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$OMNIROUTE_VERSION" ] && [ -f "$APP_DIR/dist/server.js" ]; then
  info "OmniRoute $OMNIROUTE_VERSION already present — skipping download"
else
  info "Downloading OmniRoute $OMNIROUTE_VERSION (~132 MB)..."
  DL_DIR="$(mktemp -d)"
  TMP_TGZ="$DL_DIR/omniroute.tgz"
  # -f: a proxy error page must fail loudly instead of unpacking HTML.
  curl -fsSL --retry 3 --retry-delay 2 "$TARBALL_URL" -o "$TMP_TGZ" \
    || die "download failed: $TARBALL_URL"
  [ -s "$TMP_TGZ" ] || die "download produced an empty file"

  info "Extracting..."
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  tar -xzf "$TMP_TGZ" -C "$APP_DIR" --strip-components=1
  rm -rf "$DL_DIR"

  [ -f "$APP_DIR/dist/server.js" ] || die "extracted tree is missing dist/server.js"
  printf '%s' "$OMNIROUTE_VERSION" > "$STAMP"
  ok "OmniRoute $OMNIROUTE_VERSION extracted to $APP_DIR"
fi

# ---------------------------------------------------------------------------
# 2. Runtime dependencies.
#    The npm tarball ships NO node_modules, but dist/server.js requires `next`
#    plus ~83 runtime deps at load time.
#
#    --omit=optional: the 8 optionals pull onnxruntime-node (~300 MB) and keytar.
#      Upstream is fail-soft by design — LLMLingua compression / native sqlite
#      vec stay disabled, the app runs fine without them.
#    --omit=dev: no test/build toolchain needed at runtime.
#    --ignore-scripts: skips better-sqlite3/sharp native builds — the disk and
#      memory hogs; they are optional anyway.
#    --legacy-peer-deps: REQUIRED. Upstream ships marked@18 while marked-terminal@7
#      peers marked <16, so a plain `npm install` dies with ERESOLVE.
#    --maxsockets 2: IMPORTANT. npm's default parallel fetches blow past small
#      container memory during install (SIGKILL / exit 137). Serial-ish fetches
#      keep peak RSS inside a 2 GB workload.
# ---------------------------------------------------------------------------
if [ ! -f "$APP_DIR/node_modules/zod/v4/classic/external.js" ] \
   || [ ! -f "$APP_DIR/node_modules/next/package.json" ]; then
  info "Installing runtime dependencies (first boot: 5-15 minutes)..."
  warn "If the container is restarted mid-install, this step starts over — app dir is rebuilt, data is untouched."

  # npm's download cache roughly doubles peak disk during install. On a 2 GB
  # storage quota that is the difference between fitting and ENOSPC, so keep
  # the cache in a scratch dir we delete immediately afterwards.
  NPM_CACHE_DIR="$APP_DIR/.npm-cache"
  rm -rf "$NPM_CACHE_DIR"
  mkdir -p "$NPM_CACHE_DIR"
  export npm_config_cache="$NPM_CACHE_DIR"

  # Retry loop: a 2 GB container can OOM-kill npm partway (exit 137). npm install
  # is resumable, so retry instead of dying on the first kill.
  attempt=1
  until ( cd "$APP_DIR" \
          && npm install \
               --omit=dev \
               --omit=optional \
               --ignore-scripts \
               --legacy-peer-deps \
               --maxsockets 2 \
               --no-progress \
               --no-audit \
               --no-fund \
               --loglevel=error ); do
    if [ "$attempt" -ge 6 ]; then
      rm -rf "$NPM_CACHE_DIR"
      die "npm install failed after $attempt attempts — check free disk in $APP_DIR"
    fi
    warn "npm install attempt $attempt failed (exit code above; 137 = OOM kill) — retrying..."
    attempt=$((attempt + 1))
    sleep 5
  done

  # The cache is only needed while fetching.
  rm -rf "$NPM_CACHE_DIR"
  unset npm_config_cache
  # A half-written tree from an interrupted install (missing zod internals) is
  # silently broken, not loud — verify the two canary files explicitly.
  [ -f "$APP_DIR/node_modules/zod/v4/classic/external.js" ] || die "node_modules corrupt (zod incomplete) — rm -rf $APP_DIR/node_modules and restart"
  [ -f "$APP_DIR/node_modules/next/package.json" ]        || die "node_modules corrupt (next incomplete) — rm -rf $APP_DIR/node_modules and restart"
  ok "Runtime dependencies installed"
else
  info "Runtime dependencies already present"
fi

# ---------------------------------------------------------------------------
# 3. Environment. No secrets here: the master/bootstrap password is generated
#    on first boot and printed to the console log (look for BOOTSTRAP).
# ---------------------------------------------------------------------------
export DATA_DIR="$DATA_DIR"

# Botkeep's public hostname reaches us from outside the container.
export HOSTNAME="0.0.0.0"
export PORT="$APP_PORT"

# NOTE: do NOT set DASHBOARD_PORT / API_PORT / LIVE_WS_PORT here.
# Those are host-side port mappings for the multi-container docker-compose
# layout. In the single-process standalone server they are internal, and
# pointing LIVE_WS_PORT at $PORT makes the dashboard WebSocket collide with the
# main HTTP listener ("listen EADDRINUSE"), so the WS daemon dies at boot.
# Their defaults (20128/20129/20132, loopback) are all reachable in-process.

# Auth ON. Botkeep's endpoint is a public hostname; an anonymous /v1 proxy on
# the internet is an unlimited bill against Boss's provider quotas.
export REQUIRE_API_KEY=true

# 2 GB workload: cap V8 old-space so a long agent session degrades instead of
# getting the whole container SIGKILLed.
export OMNIROUTE_MEMORY_MB="${OMNIROUTE_MEMORY_MB:-1400}"

# Single container — no Redis sidecar reachable, use the embedded path.
unset REDIS_URL 2>/dev/null || true

ok "Starting OmniRoute $OMNIROUTE_VERSION on 0.0.0.0:$APP_PORT"
ok "Data dir: $DATA_DIR"

cd "$APP_DIR"
exec node --max-old-space-size="${OMNIROUTE_MEMORY_MB}" dist/server.js
