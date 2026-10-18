# Shared API modules

`API_SPEC.md` is the binding contract. `api/index.ts` is the Deno entry point; `_shared/router.ts` is the small HTTP dispatcher. There are no third-party runtime dependencies.

- `env.ts`: fail-closed configuration and exact CORS origins.
- `http.ts`, `errors.ts`: bounded JSON parsing, request IDs, canonical envelopes, weak/strong ETag matching and safe errors.
- `auth.ts`, `clients.ts`, `accounts.ts`: Auth-verified user context, isolated user/service clients, protected admin check and account response.
- `validation.ts`: strict request/query schemas, Unicode limits and RFC3339 validation.
- `idempotency.ts`: key validation and canonical hashing; SQL owns atomic reservation/replay.
- `cursor.ts`: HMAC-signed history cursor bound to user and filters, preserving database microseconds.
- `sessions.ts`: candidate detail/history reads through RLS, safe reference projection.
- `progress.ts`: strict analytics query options and one user-scoped progress RPC; calendar/timing/score calculations remain in PostgreSQL with RLS. See `backend/PHASE5_NOTES.md`.
- `logging.ts`: explicit operational log allowlist; never pass request bodies or raw errors.
- `feedback/`: strict report schema, prompts, output validation, scoring, Gemini adapter, report serialization, retry decisions and durable worker orchestration. See `feedback/README.md`.
- `paper/`: owner-bound upload capabilities, bounded image/container/checksum validation, isolated private Storage, Vision OAuth/adapter, review mapping, transactional confirmation, OCR worker and cleanup. See `paper/README.md`. The v1.1.1 upload relay contract was explicitly approved after verifying standard signed-upload expiry incompatibility.

SQL private helpers accept clocks only for deterministic service-context database tests. The public mutation RPC always captures database statement time. Browser roles cannot execute it. Do not expose helpers, copy caller headers into the service client, derive roles from metadata, or put secrets in function source.

Progress uses a private read-only clock with no arguments; its public RPC has
no clock override. The local test harness replaces that private definition and
restores it exactly, rather than adding an API or environment test backdoor.

Run `npm run test:api:unit`; serve the local function and run `npm run test:api:http` for real Auth/RLS/concurrency coverage. The local Kong proxy intercepts browser preflights with its own wildcard CORS plugin, so the HTTP suite verifies the served function's exact-origin allowlist directly over the existing Docker network. See `backend/README.md` for setup, migrations, deferred features and limitations.
