#!/usr/bin/env bash
#
# provision-client.sh — stand up a dedicated OmniRoute instance for one client.
#
# Model: the client owns every upstream provider credential. This script only
# provisions the routing layer (container, per-client secrets, golden config,
# scoped API key). No provider credentials are created, copied, or shared here —
# the client connects their own accounts through the dashboard wizard afterwards.
#
# Usage:
#   ./provision-client.sh --client acme --port 20130
#   ./provision-client.sh --client acme --port 20130 --golden golden/acme-base.sqlite
#   ./provision-client.sh --client acme --port 20130 --dry-run
#
# See README.md for the full runbook.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────

CLIENT=""
PORT=""
GOLDEN=""
GOLDEN_PASSWORD="${GOLDEN_PASSWORD:-}"
IMAGE="diegosouzapw/omniroute:latest"
BIND_ADDR="127.0.0.1"
SECRETS_DIR="$SCRIPT_DIR/secrets"
HEALTH_TIMEOUT=120
COOKIE_SECURE="false"
DRY_RUN=0

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --client NAME         Client identifier (required). [a-z0-9-], used for the
                        container name and the data volume.
  --port N              Host port to bind (required).
  --golden PATH         Golden config .sqlite to import. Optional.
  --golden-password PW  Dashboard password baked into the golden image.
                        Required with --golden (or set GOLDEN_PASSWORD).
  --image REF           Container image. Default: diegosouzapw/omniroute:latest
  --bind ADDR           Host bind address. Default: 127.0.0.1 (loopback only).
  --secrets-dir PATH    Where to write the per-client secret file.
  --health-timeout N    Seconds to wait for readiness. Default: 120
  --cookie-secure       Set AUTH_COOKIE_SECURE=true (required behind TLS).
  --dry-run             Print what would happen; touch nothing.
  -h, --help            This text.
EOF
}

# ── Args ─────────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --client)          CLIENT="${2:-}"; shift 2 ;;
    --port)            PORT="${2:-}"; shift 2 ;;
    --golden)          GOLDEN="${2:-}"; shift 2 ;;
    --golden-password) GOLDEN_PASSWORD="${2:-}"; shift 2 ;;
    --image)           IMAGE="${2:-}"; shift 2 ;;
    --bind)            BIND_ADDR="${2:-}"; shift 2 ;;
    --secrets-dir)     SECRETS_DIR="${2:-}"; shift 2 ;;
    --health-timeout)  HEALTH_TIMEOUT="${2:-}"; shift 2 ;;
    --cookie-secure)   COOKIE_SECURE="true"; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown option: $1 (try --help)" ;;
  esac
done

# ── Preflight ────────────────────────────────────────────────────────────────

[ -n "$CLIENT" ] || die "--client is required"
[ -n "$PORT" ]   || die "--port is required"

printf '%s' "$CLIENT" | grep -Eq '^[a-z0-9][a-z0-9-]{0,38}$' \
  || die "--client must match [a-z0-9][a-z0-9-]{0,38} (got: $CLIENT)"
printf '%s' "$PORT" | grep -Eq '^[0-9]{2,5}$' \
  || die "--port must be numeric (got: $PORT)"

require_cmd curl openssl
[ "$DRY_RUN" -eq 1 ] || require_cmd docker

CONTAINER_NAME="omniroute-$CLIENT"
VOLUME_NAME="omniroute-$CLIENT-data"
BASE_URL="http://${BIND_ADDR}:${PORT}"

if [ -n "$GOLDEN" ]; then
  [ -f "$GOLDEN" ] || die "golden config not found: $GOLDEN"
  [ -n "$GOLDEN_PASSWORD" ] || die "--golden-password (or GOLDEN_PASSWORD) is required with --golden

The import replaces the ENTIRE database, including the stored dashboard
password. The script must re-authenticate with the golden image's password
before it can rotate it to this client's own. See README.md § Golden config."
fi

if [ "$DRY_RUN" -eq 0 ] && docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  die "container already exists: $CONTAINER_NAME (remove it first, or pick another --client)"
fi

# ── Secrets ──────────────────────────────────────────────────────────────────
#
# Every secret is generated per client. Nothing is inherited from the golden
# image or shared between instances: a leaked credential for one client must
# never decrypt or authenticate against another's data.

log "generating per-client secrets"
JWT_SECRET="$(gen_jwt_secret)"
API_KEY_SECRET="$(gen_hex32)"
STORAGE_ENCRYPTION_KEY="$(gen_hex32)"
INITIAL_PASSWORD="$(gen_password)"
DASHBOARD_PASSWORD="$(gen_password)"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF >&2

${C_BOLD}DRY RUN${C_RESET} — no changes made.

  container   $CONTAINER_NAME
  volume      $VOLUME_NAME
  image       $IMAGE
  bind        ${BIND_ADDR}:${PORT}
  base url    $BASE_URL
  golden      ${GOLDEN:-<none>}
  secrets     $SECRETS_DIR/$CLIENT.env
  cookie      AUTH_COOKIE_SECURE=$COOKIE_SECURE

  Steps that would run:
    1. docker run (4 generated secrets, REQUIRE_API_KEY=true)
    2. wait for /api/monitoring/health (timeout ${HEALTH_TIMEOUT}s)
    3. login with generated INITIAL_PASSWORD
$( [ -n "$GOLDEN" ] && printf '    4. import golden config, re-login with golden password\n' )
    5. rotate dashboard password to a fresh per-client value
    6. create scoped client API key
    7. write secrets file (mode 0600)
EOF
  exit 0
fi

# ── 1. Container ─────────────────────────────────────────────────────────────

log "starting $CONTAINER_NAME on ${BIND_ADDR}:${PORT}"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --stop-timeout 40 \
  -p "${BIND_ADDR}:${PORT}:20128" \
  -v "${VOLUME_NAME}:/app/data" \
  -e DATA_DIR=/app/data \
  -e JWT_SECRET="$JWT_SECRET" \
  -e API_KEY_SECRET="$API_KEY_SECRET" \
  -e STORAGE_ENCRYPTION_KEY="$STORAGE_ENCRYPTION_KEY" \
  -e INITIAL_PASSWORD="$INITIAL_PASSWORD" \
  -e REQUIRE_API_KEY=true \
  -e AUTH_COOKIE_SECURE="$COOKIE_SECURE" \
  "$IMAGE" >/dev/null \
  || die "docker run failed"
ok "container started"

# ── 2. Readiness ─────────────────────────────────────────────────────────────

wait_for_health "$BASE_URL" "$HEALTH_TIMEOUT"

# ── 3. Session ───────────────────────────────────────────────────────────────

COOKIE_JAR="$(mktemp)"
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

log "authenticating"
login "$BASE_URL" "$INITIAL_PASSWORD" "$COOKIE_JAR" \
  || die "login failed with the generated INITIAL_PASSWORD"
ok "authenticated"

ACTIVE_PASSWORD="$INITIAL_PASSWORD"

# ── 4. Golden config ─────────────────────────────────────────────────────────
#
# ORDER MATTERS. /api/db-backups/import replaces the whole SQLite file, so it
# must run BEFORE the client API key is minted — otherwise the import drops the
# api_keys row that was just created. It also replaces the stored dashboard
# password, so the session has to be re-established with the golden password.

if [ -n "$GOLDEN" ]; then
  log "importing golden config: $GOLDEN"
  import_response="$(curl -sS --max-time 120 \
    -b "$COOKIE_JAR" \
    -X POST "$BASE_URL/api/db-backups/import" \
    -F "file=@${GOLDEN}" 2>&1)" || die "golden import request failed: $import_response"

  if printf '%s' "$import_response" | grep -q '"error"'; then
    die "golden import rejected: $(json_field "$import_response" error || printf '%s' "$import_response")"
  fi
  ok "golden config imported"

  log "re-authenticating with the golden image password"
  rm -f "$COOKIE_JAR"; COOKIE_JAR="$(mktemp)"
  login "$BASE_URL" "$GOLDEN_PASSWORD" "$COOKIE_JAR" \
    || die "re-login failed — --golden-password does not match the password stored in $GOLDEN"
  ACTIVE_PASSWORD="$GOLDEN_PASSWORD"
  ok "re-authenticated"
fi

# ── 5. Password rotation ─────────────────────────────────────────────────────
#
# Without this the client would inherit whatever password the golden image
# carries, which is identical across every instance built from it.

log "rotating dashboard password to a per-client value"
rotate_body="$(printf '{"currentPassword":"%s","newPassword":"%s"}' \
  "$ACTIVE_PASSWORD" "$DASHBOARD_PASSWORD")"
rotate_response="$(curl -sS --max-time 30 \
  -b "$COOKIE_JAR" \
  -X PATCH "$BASE_URL/api/settings" \
  -H 'Content-Type: application/json' \
  -d "$rotate_body" 2>&1)" || die "password rotation request failed: $rotate_response"

if printf '%s' "$rotate_response" | grep -q '"code":"PASSWORD_'; then
  die "password rotation rejected: $rotate_response"
fi
ok "dashboard password rotated"

# ── 6. Client API key ────────────────────────────────────────────────────────

log "creating scoped client API key"
key_body="$(printf '{"name":"%s","usageLimitEnabled":true,"allowUsageCommand":true}' "$CLIENT")"
key_response="$(curl -sS --max-time 30 \
  -b "$COOKIE_JAR" \
  -X POST "$BASE_URL/api/keys" \
  -H 'Content-Type: application/json' \
  -d "$key_body" 2>&1)" || die "key creation request failed: $key_response"

CLIENT_API_KEY="$(json_field "$key_response" key)" \
  || die "could not read the new key from the response: $key_response"
ok "client API key created"

# ── 7. Persist ───────────────────────────────────────────────────────────────

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
SECRETS_FILE="$SECRETS_DIR/$CLIENT.env"

umask 077
cat > "$SECRETS_FILE" <<EOF
# OmniRoute — $CLIENT
# Generated by onboarding/provision-client.sh
#
# Operator-only. Do not commit. Do not send the container secrets to the
# client — they only ever need OMNIROUTE_BASE_URL, the API key, and the
# dashboard password.

OMNIROUTE_CLIENT=$CLIENT
OMNIROUTE_CONTAINER=$CONTAINER_NAME
OMNIROUTE_VOLUME=$VOLUME_NAME
OMNIROUTE_BASE_URL=$BASE_URL

# Client-facing
OMNIROUTE_API_KEY=$CLIENT_API_KEY
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD

# Container secrets — required to recreate this container against the same
# volume. Losing STORAGE_ENCRYPTION_KEY makes the stored credentials
# unrecoverable.
JWT_SECRET=$JWT_SECRET
API_KEY_SECRET=$API_KEY_SECRET
STORAGE_ENCRYPTION_KEY=$STORAGE_ENCRYPTION_KEY
EOF
chmod 600 "$SECRETS_FILE"
ok "secrets written to $SECRETS_FILE (0600)"

# ── Handover ─────────────────────────────────────────────────────────────────

cat <<EOF

${C_BOLD}$CLIENT is provisioned.${C_RESET}

Send the client this block:

  Dashboard   $BASE_URL
  Password    $DASHBOARD_PASSWORD

  Base URL    $BASE_URL/v1
  API Key     $CLIENT_API_KEY
  Model       auto

Their remaining step — connecting their own provider accounts:

  1. Open the dashboard, go to Providers.
  2. Auto-import picks up any Kiro / Cursor / Codex CLI they already use.
  3. OAuth click-through for Claude, GitHub, Kiro, Cursor and the rest.
  4. Bulk-paste keys for Mistral / Groq / Gemini / Cerebras.

Operator notes:

  logs        docker logs -f $CONTAINER_NAME
  health      curl -sS $BASE_URL/api/monitoring/health
  remote ops  omniroute connect $BASE_URL   # then: omniroute --context <name> cost
  secrets     $SECRETS_FILE

EOF
