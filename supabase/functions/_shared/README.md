# Shared API modules

`API_SPEC.md` is the binding contract. `api/index.ts` is the Deno entry point; `_shared/router.ts` is the small HTTP dispatcher. There are no third-party runtime dependencies.

- `env.ts`: fail-closed configuration and exact CORS origins.
- `http.ts`, `errors.ts`: bounded JSON parsing, request IDs, canonical envelopes, weak/strong ETag matching and safe errors.
- `auth.ts`, `clients.ts`, `accounts.ts`: Auth-verified user context, isolated user/service clients, protected admin check and account response.
- `validation.ts`: strict request/query schemas, Unicode limits and RFC3339 validation.
- `idempotency.ts`: key validation and canonical hashing; SQL owns atomic reservation/replay.
- `cursor.ts`: HMAC-signed history cursor bound to user and filters, preserving database microseconds.
- `sessions.ts`: candidate detail/history reads through RLS, safe reference projection.
- `logging.ts`: explicit operational log allowlist; never pass request bodies or raw errors.

SQL private helpers accept clocks only for deterministic service-context database tests. The public mutation RPC always captures database statement time. Browser roles cannot execute it. Do not expose helpers, copy caller headers into the service client, derive roles from metadata, or put secrets in function source.

Run `npm run test:api:unit`; serve the local function and run `npm run test:api:http` for real Auth/RLS/concurrency coverage. The local Kong proxy intercepts browser preflights with its own wildcard CORS plugin, so the HTTP suite verifies the served function's exact-origin allowlist directly over the existing Docker network. See `backend/README.md` for setup, migrations, deferred features and limitations.
