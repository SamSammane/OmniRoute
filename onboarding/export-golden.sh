#!/usr/bin/env bash
#
# export-golden.sh — capture a template instance's config as a golden .sqlite.
#
# The golden image is the tuned configuration you want every client to start
# with: combos, routing strategy, compression settings, policies, model aliases,
# quota rules.
#
# ⚠️  /api/db-backups/export returns the ENTIRE database, not a config-only
# bundle. Anything configured on the template instance travels with it —
# including provider_connections (encrypted upstream credentials) and api_keys.
# Build the template with ZERO provider accounts connected. See README.md.
#
# Usage:
#   ./export-golden.sh --url http://127.0.0.1:20128 --password <pw> \
#                      --out golden/base-v1.sqlite

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

BASE_URL=""
PASSWORD=""
OUT=""
FORCE=0

usage() {
  cat <<'EOF'
export-golden.sh — capture a template instance's config as a golden .sqlite

Options:
  --url URL         Template instance base URL (required).
  --password PW     Template dashboard password (required).
  --out PATH        Destination .sqlite path (required).
  --force           Skip the provider-connection safety check.
  -h, --help        This text.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url)      BASE_URL="${2:-}"; shift 2 ;;
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --out)      OUT="${2:-}"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$BASE_URL" ] || die "--url is required"
[ -n "$PASSWORD" ] || die "--password is required"
[ -n "$OUT" ]      || die "--out is required"

require_cmd curl

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

log "authenticating against $BASE_URL"
login "$BASE_URL" "$PASSWORD" "$COOKIE_JAR" || die "login failed"
ok "authenticated"

# Safety check: a golden image with provider credentials in it would copy one
# operator's upstream accounts into every client instance — exactly the
# arrangement the BYOK model exists to avoid.
if [ "$FORCE" -eq 0 ]; then
  log "checking the template has no provider connections"
  providers_response="$(curl -sS --max-time 30 -b "$COOKIE_JAR" \
    "$BASE_URL/api/providers" 2>&1)" || providers_response=""

  if printf '%s' "$providers_response" | grep -q '"apiKey"\|"accessToken"\|"refreshToken"'; then
    die "the template instance has provider credentials configured.

A golden image is copied verbatim into every client instance, so those
credentials would be shared across all of them. Disconnect every provider on
the template, or re-run with --force if you have verified this is intended."
  fi
  ok "no provider credentials detected"
fi

mkdir -p "$(dirname -- "$OUT")"
log "exporting database"
curl -sS -f --max-time 300 -b "$COOKIE_JAR" \
  "$BASE_URL/api/db-backups/export" \
  -o "$OUT" || die "export failed"

[ -s "$OUT" ] || die "export produced an empty file: $OUT"

# The import route validates these tables before accepting a bundle; checking
# here means a bad golden image fails at capture time, not mid-provision.
if command -v sqlite3 >/dev/null 2>&1; then
  for table in provider_connections provider_nodes combos api_keys; do
    sqlite3 "$OUT" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1 \
      || warn "table '$table' missing or unreadable — import may reject this file"
  done
fi

ok "golden config written to $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"

cat <<EOF

Use it with:

  ./provision-client.sh --client <name> --port <port> \\
      --golden $OUT --golden-password '<template password>'

The template's dashboard password is baked into the file. provision-client.sh
needs it to re-authenticate after import, then rotates it to a per-client value.

EOF
