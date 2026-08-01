#!/usr/bin/env bash
#
# smoke.test.sh — validation and dry-run coverage for the onboarding scripts.
#
# Runs without Docker and without a live OmniRoute instance: everything here
# exercises argument parsing, input validation, and the helper functions. The
# provisioning path itself is covered by --dry-run.
#
#   ./tests/smoke.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ONBOARDING_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROVISION="$ONBOARDING_DIR/provision-client.sh"
EXPORT_GOLDEN="$ONBOARDING_DIR/export-golden.sh"

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# Assert the command exits non-zero and its output matches a pattern.
assert_rejects() {
  local desc="$1" pattern="$2"; shift 2
  local output status
  output="$("$@" 2>&1)"; status=$?
  if [ "$status" -eq 0 ]; then
    fail "$desc" "expected non-zero exit, got 0"
  elif ! printf '%s' "$output" | grep -q -- "$pattern"; then
    fail "$desc" "expected output matching '$pattern', got: $(printf '%s' "$output" | head -2)"
  else
    pass "$desc"
  fi
}

assert_succeeds() {
  local desc="$1" pattern="$2"; shift 2
  local output status
  output="$("$@" 2>&1)"; status=$?
  if [ "$status" -ne 0 ]; then
    fail "$desc" "expected exit 0, got $status: $(printf '%s' "$output" | head -3)"
  elif ! printf '%s' "$output" | grep -q -- "$pattern"; then
    fail "$desc" "expected output matching '$pattern', got: $(printf '%s' "$output" | head -3)"
  else
    pass "$desc"
  fi
}

printf '\nonboarding smoke tests\n\n'

# ── Executability ────────────────────────────────────────────────────────────

printf 'executability\n'
for f in "$PROVISION" "$EXPORT_GOLDEN"; do
  if [ -x "$f" ]; then pass "$(basename "$f") is executable"
  else fail "$(basename "$f") is executable" "not executable"; fi
done

# ── provision-client.sh argument validation ──────────────────────────────────

printf '\nprovision-client.sh validation\n'

assert_rejects "requires --client" "client is required" \
  "$PROVISION" --port 20130

assert_rejects "requires --port" "port is required" \
  "$PROVISION" --client acme

assert_rejects "rejects uppercase client names" "must match" \
  "$PROVISION" --client ACME --port 20130

assert_rejects "rejects client names with slashes" "must match" \
  "$PROVISION" --client "a/../b" --port 20130

assert_rejects "rejects non-numeric ports" "must be numeric" \
  "$PROVISION" --client acme --port abc

assert_rejects "rejects unknown options" "unknown option" \
  "$PROVISION" --client acme --port 20130 --nope

assert_rejects "rejects a missing golden file" "golden config not found" \
  "$PROVISION" --client acme --port 20130 --golden /nonexistent/g.sqlite

# The golden password guard is the one that prevents a silent half-provision:
# without it the script would import, then fail to re-authenticate.
GOLDEN_TMP="$(mktemp)"
assert_rejects "requires --golden-password with --golden" "golden-password" \
  env -u GOLDEN_PASSWORD "$PROVISION" --client acme --port 20130 --golden "$GOLDEN_TMP"

# ── provision-client.sh dry run ──────────────────────────────────────────────

printf '\nprovision-client.sh dry run\n'

assert_succeeds "dry run reports the plan" "DRY RUN" \
  "$PROVISION" --client acme --port 20130 --dry-run

assert_succeeds "dry run names the container" "omniroute-acme" \
  "$PROVISION" --client acme --port 20130 --dry-run

assert_succeeds "dry run binds loopback by default" "127.0.0.1:20130" \
  "$PROVISION" --client acme --port 20130 --dry-run

assert_succeeds "dry run honours --bind" "0.0.0.0:20130" \
  "$PROVISION" --client acme --port 20130 --bind 0.0.0.0 --dry-run

assert_succeeds "dry run lists the golden import step" "import golden config" \
  "$PROVISION" --client acme --port 20130 --dry-run \
  --golden "$GOLDEN_TMP" --golden-password secret

assert_succeeds "dry run omits the golden step without --golden" "rotate dashboard password" \
  "$PROVISION" --client acme --port 20130 --dry-run

# A dry run must not create anything.
if [ -d "$ONBOARDING_DIR/secrets" ] && [ -n "$(ls -A "$ONBOARDING_DIR/secrets" 2>/dev/null)" ]; then
  fail "dry run leaves no secrets behind" "secrets/ is not empty"
else
  pass "dry run leaves no secrets behind"
fi

rm -f "$GOLDEN_TMP"

# ── export-golden.sh argument validation ─────────────────────────────────────

printf '\nexport-golden.sh validation\n'

assert_rejects "requires --url" "url is required" \
  "$EXPORT_GOLDEN" --password pw --out /tmp/g.sqlite

assert_rejects "requires --password" "password is required" \
  "$EXPORT_GOLDEN" --url http://127.0.0.1:20128 --out /tmp/g.sqlite

assert_rejects "requires --out" "out is required" \
  "$EXPORT_GOLDEN" --url http://127.0.0.1:20128 --password pw

assert_rejects "rejects unknown options" "unknown option" \
  "$EXPORT_GOLDEN" --url http://127.0.0.1:20128 --password pw --out /tmp/g.sqlite --nope

# ── helpers ──────────────────────────────────────────────────────────────────

printf '\nlib/common.sh helpers\n'

# shellcheck source=../lib/common.sh
. "$ONBOARDING_DIR/lib/common.sh"
# common.sh sets `set -euo pipefail` for the scripts that source it; the test
# runner needs the opposite, so a failing assertion reports instead of aborting.
set +e +o pipefail

pw="$(gen_password)"
if printf '%s' "$pw" | grep -Eq '^[A-Za-z0-9]{32}$'; then
  pass "gen_password produces 32 alphanumeric chars"
else
  fail "gen_password produces 32 alphanumeric chars" "got: $pw"
fi

# Distinct values on repeat calls — a fixed secret across clients would be a
# cross-tenant credential leak.
if [ "$(gen_password)" != "$(gen_password)" ]; then
  pass "gen_password differs between calls"
else
  fail "gen_password differs between calls" "two calls returned the same value"
fi

if printf '%s' "$(gen_hex32)" | grep -Eq '^[0-9a-f]{64}$'; then
  pass "gen_hex32 produces 64 hex chars"
else
  fail "gen_hex32 produces 64 hex chars" "got: $(gen_hex32)"
fi

if [ "$(printf '%s' "$(gen_jwt_secret)" | wc -l | tr -d ' ')" = "0" ]; then
  pass "gen_jwt_secret is newline-free"
else
  fail "gen_jwt_secret is newline-free" "contains a newline"
fi

if [ "$(json_field '{"key":"omr_abc123","name":"acme"}' key)" = "omr_abc123" ]; then
  pass "json_field extracts a string field"
else
  fail "json_field extracts a string field" "got: $(json_field '{"key":"omr_abc123"}' key)"
fi

if json_field '{"name":"acme"}' key >/dev/null 2>&1; then
  fail "json_field fails on a missing field" "expected non-zero exit"
else
  pass "json_field fails on a missing field"
fi

if json_field 'not json at all' key >/dev/null 2>&1; then
  fail "json_field fails on malformed input" "expected non-zero exit"
else
  pass "json_field fails on malformed input"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

printf '\n%d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
