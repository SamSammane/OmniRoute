# shellcheck shell=bash
#
# Shared helpers for the client onboarding scripts.
#
# Sourced by provision-client.sh and export-golden.sh. Never executed directly.

set -euo pipefail

# ── Output ───────────────────────────────────────────────────────────────────

if [ -t 2 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""
fi

log()  { printf '%s→%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# ── Secrets ──────────────────────────────────────────────────────────────────

# Generate a URL/JSON-safe password.
#
# Deliberately restricted to [A-Za-z0-9] so the value can be embedded in JSON
# bodies and shell arguments without escaping. Length compensates for the
# reduced alphabet: 32 chars of base62 is ~190 bits.
#
# Sourced from `openssl rand` rather than `tr </dev/urandom | head -c`: `head`
# closes the pipe at 32 bytes, which kills `tr` with SIGPIPE and fails the whole
# pipeline under `set -o pipefail`. `cut` reads to EOF, so nothing gets signalled.
# 64 random bytes is 88 base64 chars; stripping +/= leaves ~82, comfortably
# above the 32 needed.
gen_password() {
  openssl rand -base64 64 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32
}

gen_jwt_secret()        { openssl rand -base64 48 | tr -d '\n'; }
gen_hex32()             { openssl rand -hex 32; }

# ── HTTP ─────────────────────────────────────────────────────────────────────

# Wait until the instance answers its health probe.
#
# Targets /api/monitoring/health — the same endpoint the container's own
# HEALTHCHECK uses (scripts/dev/healthcheck.mjs), so "ready" here means the
# same thing Docker means by healthy.
wait_for_health() {
  local base_url="$1" timeout="${2:-120}" waited=0
  log "waiting for $base_url to become healthy (timeout ${timeout}s)"
  while [ "$waited" -lt "$timeout" ]; do
    if curl -sS -o /dev/null -f --max-time 5 "$base_url/api/monitoring/health" 2>/dev/null; then
      ok "instance healthy after ${waited}s"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  die "instance did not become healthy within ${timeout}s — check: docker logs ${CONTAINER_NAME:-<container>}"
}

# POST /api/auth/login, storing the auth_token cookie in a jar.
#
# The dashboard JWT is one of the credentials requireManagementAuth() accepts,
# and it is the only one obtainable over HTTP from a cold instance — the CLI
# machine-id token is loopback-only and manage-scope API keys do not exist yet.
login() {
  local base_url="$1" password="$2" jar="$3" body
  body=$(printf '{"password":"%s"}' "$password")
  if ! curl -sS -f --max-time 15 \
      -c "$jar" \
      -X POST "$base_url/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d "$body" >/dev/null 2>&1; then
    return 1
  fi
  # A 200 with no cookie means the password was accepted but no session was
  # issued — treat that as a failure rather than proceeding unauthenticated.
  grep -q 'auth_token' "$jar" 2>/dev/null || return 1
  return 0
}

# Extract a top-level string field from a JSON object.
#
# Uses python3 when available (correct), falling back to a narrow grep for
# environments without it. The fallback only handles flat string values, which
# is all the two call sites need (`key`, `error`).
json_field() {
  local json="$1" field="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
value = data.get(sys.argv[1]) if isinstance(data, dict) else None
if value is None:
    sys.exit(1)
print(value)
' "$field" 2>/dev/null || return 1
  else
    printf '%s' "$json" \
      | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' \
      | grep . || return 1
  fi
}
