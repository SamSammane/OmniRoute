# Client Onboarding

Provisioning scripts for running a dedicated OmniRoute instance per client.

## The model

**The client owns every upstream provider credential.** These scripts provision
the routing layer only — container, per-client secrets, tuned configuration, a
scoped API key. No provider account is ever created, copied, or shared by this
tooling.

That boundary is deliberate, and it is what keeps the arrangement clean. Most
provider terms prohibit third-party access to an account regardless of whether
money changes hands — the clauses are written around _who accesses the service_,
not around resale. Compare the language in
[`docs/reference/FREE_TIERS.md`](../docs/reference/FREE_TIERS.md):

| Provider   | Clause                                                                                   |
| ---------- | ---------------------------------------------------------------------------------------- |
| `opencode` | "your own internal use, and **not on behalf of or for the benefit of** any third party"  |
| `nlpcloud` | prohibits "setting up a proxy … that **allows others to access** the Service through it" |
| `modal`    | §1.3 — "rent, resell, **or otherwise allow any third party direct access**"              |

Under BYOK none of those are engaged: the client's account, the client's
instance, the client's own single-user proxy. You provide the automation, the
tuned routing, and the ops.

> Terms change constantly (this table was last researched 2026-06-18). Re-verify
> before standardising on any provider, and get a lawyer's read on the
> commercial structure.

## Layout

```
onboarding/
├── provision-client.sh   # stand up one client instance end to end
├── export-golden.sh      # capture a template instance's config
├── lib/common.sh         # shared helpers
├── tests/smoke.test.sh   # validation + dry-run coverage (no Docker needed)
├── golden/               # golden .sqlite images (gitignored)
└── secrets/              # per-client secret files, 0600 (gitignored)
```

## Quick start

```bash
# 1. See the plan without touching anything
./provision-client.sh --client acme --port 20130 --dry-run

# 2. Provision for real
./provision-client.sh --client acme --port 20130

# 3. With a golden config
./provision-client.sh --client acme --port 20130 \
    --golden golden/base-v1.sqlite --golden-password "$TEMPLATE_PW"
```

Run the tests any time:

```bash
./tests/smoke.test.sh
```

## What provision-client.sh does

1. **Validates** the client name and port, and checks the container name is free.
2. **Generates four secrets, per client** — `JWT_SECRET`, `API_KEY_SECRET`,
   `STORAGE_ENCRYPTION_KEY`, and the initial dashboard password. Nothing is
   shared between instances or inherited from the golden image.
3. **Starts the container** bound to `127.0.0.1` by default, with
   `REQUIRE_API_KEY=true`.
4. **Waits for readiness** against `/api/monitoring/health` — the same endpoint
   the container's own `HEALTHCHECK` uses.
5. **Authenticates** via `POST /api/auth/login` to get the dashboard JWT.
6. **Imports the golden config** (if given), then re-authenticates.
7. **Rotates the dashboard password** to a fresh per-client value.
8. **Creates the client's scoped API key** via `POST /api/keys`.
9. **Writes `secrets/<client>.env`** at mode 0600 and prints the handover block.

## Golden config

A golden image is the tuned configuration every client starts from: combos,
routing strategy, compression, policies, model aliases, quota rules.

```bash
./export-golden.sh --url http://127.0.0.1:20128 \
    --password "$TEMPLATE_PW" --out golden/base-v1.sqlite
```

### ⚠️ The export is the whole database

`/api/db-backups/export` returns the entire SQLite file, not a config-only
bundle. Two consequences drive the design of both scripts:

**Build the template with zero providers connected.** `provider_connections`
travels with the export, so a template that has your accounts on it copies your
credentials into every client instance — precisely the arrangement BYOK exists
to avoid. `export-golden.sh` refuses to export when it detects provider
credentials; `--force` overrides only if you have verified it is intended.

**The stored dashboard password travels too.** After import, the instance's
password is the _golden image's_ password, not the `INITIAL_PASSWORD` the
container booted with. That is why `--golden-password` is mandatory: the script
re-authenticates with it, then immediately rotates to a per-client value. Skip
that rotation and every client would share one password.

### Ordering

`/api/db-backups/import` **replaces** the database, so the golden import must run
_before_ the client's API key is minted — otherwise the import drops the
`api_keys` row that was just created. `provision-client.sh` enforces this order.

## Client's onboarding step

The only thing the client does themselves is connect their own accounts:

1. **Auto-import** — picks up credentials from CLIs they already use:
   `/api/oauth/kiro/auto-import`, `cursor/auto-import`, `codex/import-token`,
   `cliproxy-import`, `trae/import`.
2. **OAuth click-through** — 12 providers are wired into the wizard
   (`providerOnboardingCatalog.ts`): `claude`, `codex`, `antigravity`, `agy`,
   `kimi-coding`, `github`, `gitlab-duo`, `kiro`, `amazon-q`, `cursor`,
   `kilocode`, `cline`.
3. **Bulk key paste** for the API-key providers — Mistral, Groq, Gemini,
   Cerebras are all free tiers with no card required.

Realistically under 10 minutes, and every credential belongs to them.

## Fleet operations

`bin/cli/` is built for remote multi-instance use:

```bash
omniroute connect http://127.0.0.1:20130   # save a named context
omniroute --context acme health
omniroute --context acme cost
omniroute --context acme doctor
```

## Constraints

- **`/api/services/` and the MCP spawn routes are loopback-only**, enforced by
  `isLocalOnlyPath()` in `src/server/authz/routeGuard.ts` _before_ any auth
  check. Those operations cannot be driven remotely — use `docker exec`.
- **`bin/` is not in the runtime image.** The Dockerfile copies only the Next.js
  standalone output, `better-sqlite3`, and `healthcheck.mjs`, so
  `bin/reset-password.mjs` is unavailable inside the container. Password
  rotation goes through `PATCH /api/settings` instead.
- **`--bind 0.0.0.0` needs TLS.** Pass `--cookie-secure` to set
  `AUTH_COOKIE_SECURE=true` whenever the instance is reachable off-loopback.

## Secrets handling

`secrets/<client>.env` is mode 0600 in a 0700 directory, and `secrets/` is
gitignored. It holds both client-facing values (API key, dashboard password) and
container secrets.

**Send the client only the API key and dashboard password.** The container
secrets exist so you can recreate the container against the same volume — in
particular, losing `STORAGE_ENCRYPTION_KEY` makes that client's stored
credentials permanently unrecoverable. Back the directory up somewhere
appropriate for key material; this repo is not it.
