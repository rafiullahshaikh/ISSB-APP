# Qiyadat Supabase backend

The repository-root `API_SPEC.md` (currently v1.1.0) is the binding API contract. This backend uses Supabase Auth, PostgreSQL, forced Row Level Security, private Storage, and one Edge Function router. There is no FastAPI backend. Existing frontend HTML remains independent and unchanged.

Phase 2 implements the authenticated API foundation and typed WAT lifecycle. See `VERIFICATION.md` for actual verification results; implementation alone is not a completion claim. Historical Phase 1 setup notes are in `PHASE1_NOTES.md`.

## Local prerequisites

Use the installed Node.js 24+, Python 3.11+, Supabase CLI 2.119.0 and Docker Desktop Linux engine. No npm dependencies are required. The CLI is installed at `C:\Users\windows10\node_modules\supabase\dist\supabase.js` on this machine. Do not link, deploy, install packages, download a missing runtime image, or change Docker/WSL settings without authorization.

The project uses ports 55321 (gateway/API), 55322 (database), 55320 (shadow database), 55323 (Studio), and 55324 (local mail). The API contract's example default port 54321 is replaced only in local commands by the existing Windows port workaround.

```powershell
$qiyadatCli = Join-Path $env:USERPROFILE 'node_modules\supabase\dist\supabase.js'
docker version
# Start existing local components only when needed. The CLI may pull missing images;
# obtain approval before a new runtime download.
node $qiyadatCli start -x studio,imgproxy,mailpit,logflare,vector,realtime,supavisor
node $qiyadatCli db reset --local
node $qiyadatCli test db
node $qiyadatCli db lint --local --level warning
node $qiyadatCli functions serve api --no-verify-jwt
```

Run from the repository root. `db reset --local` destroys only this project's local database, applies migrations in filename order, and runs `supabase/seed.sql`. Use an interactive PowerShell terminal if the Windows CLI's noninteractive process spawning fails. Never add `--linked`.

`functions serve` remains running in its terminal. The API base is `http://127.0.0.1:55321/functions/v1/api/v1`. JWT verification is disabled at the function gateway so public routes and canonical authentication errors work; the router independently validates every protected bearer token through Supabase Auth's `/auth/v1/user` endpoint. Never remove that validation.

## Environment and authentication tests

Root `.env.example` and `backend/.env.example` contain names with empty values only. Supabase automatically supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` when serving locally. Modern equivalents `SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_SECRET_KEY` are also supported. Optional `QIYADAT_ALLOWED_ORIGINS` is a comma-separated exact-origin allowlist; defaults are localhost and 127.0.0.1 on ports 8080 and 8765. `QIYADAT_RELEASE` defaults to `2026.10.0`. Store any local overrides outside tracked files. Never print or commit local keys, JWTs or real user data.

```powershell
python backend/scripts/verify_repository.py
node backend/scripts/verify_frontend.cjs
npm run test:api:unit
# With local Auth/PostgREST/database and functions serve running:
npm run test:api:http
```

The HTTP suite reads local CLI status JSON into memory, refuses hosted URLs, creates temporary synthetic `.invalid` Auth accounts through the local admin API, obtains real Auth sessions, and deletes those accounts in `finally`. Passwords and keys exist only in process memory. This is test setup, not an application password-login endpoint. Database tests use synthetic fixtures inside rollback transactions. Unit tests use built-in Node test modules and mocks; HTTP tests call the real local Edge Function.

## Routes

| Method | Route after `/v1` | Behavior |
|---|---|---|
| GET | `/health` | Database health, request ID, public short cache |
| GET | `/config/wat?kind=diagnostic\|practice` | Published immutable set, rules, ETag |
| GET / PATCH | `/me` | Own account; safe profile edits and current consent |
| POST | `/wat/sessions` | Atomic start/free-demo claim or resume; required idempotency key |
| PUT | `/wat/sessions/{id}/answers/{position}` | Owner-only typed answer and authoritative simulation timing |
| POST | `/wat/sessions/{id}/finish` | Atomic typed/paper transition; required idempotency key |
| POST | `/wat/sessions/import` | Validated guest/legacy history import; required idempotency key |
| GET | `/wat/sessions/{id}` | Own ordered snapshot and safe summary references |
| GET | `/wat/sessions` | Own summary history, documented filters, signed opaque cursor |

Protected requests require a Supabase Auth user bearer token and publishable `apikey`. Candidate reads use a separate user-scoped REST client and existing RLS. A separate service client performs narrow RPC mutations using only the Auth-verified user UUID. Public SQL RPCs used by this service have no anonymous/authenticated execution grants. `qiyadat_history` has no actor argument and executes as the authenticated user with RLS. Editable user metadata never grants admin membership; future admin checks read `admin_users` through a trusted context.

Mutations strictly reject unknown properties. Errors and logs expose safe codes and field validation messages, never SQL diagnostics or request content. CORS never reflects arbitrary origins. Authenticated responses use `private, no-store`. Idempotency stores canonical JSON hashes and exact response status/body for at least 24 hours; the table is service-only. Profile locking serializes simultaneous requests per account. Rate counters are in a private, forced-RLS table.

## Migrations and seed

The three verified Phase 1 migrations remain byte-for-byte unchanged. New migrations apply after them:

1. `20261008000100_api_primitives.sql`: protected lifetime free-demo and report markers, exact idempotency replay data, private rate counters, validation/access/idempotency helpers, supporting indexes.
2. `20261008000200_session_operations.sql`: transactional start, typed-answer, finish, import, and safe profile operations.
3. `20261008000300_api_dispatch_and_reads.sql`: service-only dispatcher, health/config/account/admin-context functions, candidate RLS history function and explicit grants.

Seed remains exactly the original 20 `diagnostic-v1` words, with 15 seconds, 2000 ms grace, 280 code points and safe feature/quota defaults. No accounts, admins or payment offers are seeded. WAT configuration is enabled; OCR, feedback, payments and beta remain disabled.

## Contract decisions and limitations

- API v1.1.0 gives one lifetime **authenticated diagnostic session**, not unlimited sessions with a single report. A new key/device/mode resumes the same unfinished writable free session. Completion or expiry cannot reset that claim. Paid or enabled-beta access allows further sessions; starting/finishing/importing consumes no report quota.
- There is no published practice set in Phase 1 seed. `kind=practice` returns `FEATURE_DISABLED` until trusted configuration publishes one; no new word bank was invented.
- The contract does not give a dedicated error for a second active paid/beta session. The existing global `SESSION_STATE_CONFLICT` code is used. Expired in-progress rows cannot be abandoned through any Phase 2 route; a future trusted recovery/abandon flow must resolve them without inventing a new state.
- Free-demo resume items include the original timing plus `answer`, `locked`, `completed`, and `time_used_ms`, as required by the specification's resume narrative.
- Acceptance uses database statement receive time, never client timestamps. `client_elapsed_ms`, when supplied, remains response-time telemetry; absent simulation telemetry is derived from server receive time and capped at 15000 ms. Imported timing is always `client_reported`.
- Natural finish before all simulation windows close reports actual completion and sets `ended_early`; future unattempted windows remain unattempted. Closed windows become blanks. No fabricated answers or future completion times are accepted.
- Protected columns reserve trusted technical recovery on the same free session. Phase 2 exposes no recovery endpoint or worker. It never grants a fresh demo after an alleged client failure.
- Provider-dependent OCR/report references are read-only summaries. No OCR, Gemini, report generation, payment/offer endpoints, admin screens, progress aggregation, privacy export/deletion workers, OTP delivery or frontend integration is implemented. These remain later phases.

A workspace without `.git` cannot prove Git tracking state. Offline checks scan source for recognizable secrets, exclude ignored local CLI state, and compare original migration, specification and HTML hashes. Do not initialize or commit a repository containing runtime artifacts without reviewing ignore rules.
