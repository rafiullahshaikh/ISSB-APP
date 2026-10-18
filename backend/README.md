# Qiyadat Supabase backend

Phases 1-5 are complete locally. Progress analytics and all preserved regression
suites pass; see VERIFICATION.md. Phase 4's upload-expiry prerequisite
was resolved by explicit user approval for a protected backend upload relay.
The standard signed-upload transport lasts two hours and bypasses insertion
RLS after issuance. See `PHASE4_NOTES.md` for the reproduced findings, S3
limitations and the approved API_SPEC.md v1.1.1 contract decision. OCR remains
disabled in normal seed defaults; no hosted function or scheduler is deployed.

The repository-root `API_SPEC.md` (currently v1.1.1) is the binding API contract. This backend uses Supabase Auth, PostgreSQL, forced Row Level Security, private Storage, and one Edge Function router. There is no FastAPI backend. Existing frontend HTML remains independent and unchanged.

Phases 1 and 2 implement the authenticated API foundation and typed WAT lifecycle. Phase 3 adds durable feedback jobs and reports; see `VERIFICATION.md` for actual verification status and `PHASE3_NOTES.md` for contract decisions. Historical Phase 1 setup notes are in `PHASE1_NOTES.md`.

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
npm run test:feedback:unit
npm run test:feedback:worker
# Starts isolated synthetic Gemini mock and local worker automatically:
npm run test:feedback:http
```

The HTTP suite reads local CLI status JSON into memory, refuses hosted URLs, creates temporary synthetic `.invalid` Auth accounts through the local admin API, obtains real Auth sessions, and deletes those accounts in `finally`. Passwords and keys exist only in process memory. This is test setup, not an application password-login endpoint. Database tests use synthetic fixtures inside rollback transactions. Unit tests use built-in Node test modules and mocks; HTTP tests call the real local Edge Function. The CLI-generated Kong proxy installs a wildcard CORS plugin, so the suite probes only preflight behavior directly over the existing Docker network; all other HTTP tests use the documented public local URL.

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
| POST | `/wat/sessions/{id}/report` | Transactional consent, eligibility, quota and durable job creation |
| GET | `/wat/sessions/{id}/report` | Complete saved report with deterministic scores and disclaimer |
| GET | `/jobs/{id}` | Owner-only safe status/result; trusted admin operational access |
| POST | `/wat/sessions/{id}/paper/uploads` | Ordered private upload authorizations; strict 15-minute capabilities |
| PUT | `/wat/sessions/{id}/paper/uploads/{upload_id}/content?token=...` | Authenticated binary relay, actual file/checksum validation, no upsert |
| POST / GET | `/wat/sessions/{id}/paper/ocr` | Idempotent durable OCR enqueue / 20-row review draft |
| PUT | `/wat/sessions/{id}/paper/confirm` | Revision-fenced canonical text and immediate image deletion/retry |
| GET | `/progress` | Own timezone-aware totals, timing, scores, streak, weekly comparison, trends and recurring weak areas |

Protected requests require a Supabase Auth user bearer token and publishable `apikey`. Candidate reads use a separate user-scoped REST client and existing RLS. A separate service client performs narrow RPC mutations using only the Auth-verified user UUID. Public SQL RPCs used by this service have no anonymous/authenticated execution grants. `qiyadat_history` has no actor argument and executes as the authenticated user with RLS. Editable user metadata never grants admin membership; future admin checks read `admin_users` through a trusted context.

Mutations strictly reject unknown properties. Errors and logs expose safe codes and field validation messages, never SQL diagnostics or request content. CORS never reflects arbitrary origins. Authenticated responses use `private, no-store`. Idempotency stores canonical JSON hashes and exact response status/body for at least 24 hours; the table is service-only. Profile locking serializes simultaneous requests per account. Rate counters are in a private, forced-RLS table.

Public WAT configuration responses use a short cache and content-derived ETag. Conditional requests accept both strong and gateway-weakened ETag forms, because the local gateway may add `W/` when compressing the response.

## Migrations and seed

The three verified Phase 1 migrations remain byte-for-byte unchanged. New migrations apply after them:

1. `20261008000100_api_primitives.sql`: protected lifetime free-demo and report markers, exact idempotency replay data, private rate counters, validation/access/idempotency helpers, supporting indexes.
2. `20261008000200_session_operations.sql`: transactional start, typed-answer, finish, import, and safe profile operations.
3. `20261008000300_api_dispatch_and_reads.sql`: service-only dispatcher, health/config/account/admin-context functions, candidate RLS history function and explicit grants.
4. `20261016000100_feedback_foundation.sql`: quota/cap helpers, report requests and narrowly guarded technical session recovery.
5. `20261016000200_feedback_worker.sql`: claim, dispatch authorization, retry, stale recovery, output validation and atomic completion.
6. `20261016000300_feedback_reads.sql`: candidate RLS report reads and safe owner/admin job reads.
7. `20261017000100_paper_operations.sql`: private relay authorization/leases, OCR quota/dispatch ledger, enqueue, confirmation and RLS draft reads.
8. `20261017000200_ocr_worker.sql`: OCR claims/fencing, page checkpoints, retries/recovery, revision completion and safe cleanup operations.
9. `20261017000300_paper_integration.sql`: guarded same-session OCR recovery/reruns, confirmed-paper eligibility in the existing report implementation and safe OCR job results.
10. `20261017000400_paper_validation_contract.sql`: preparation page-field validation uses Section 6.1's VALIDATION_ERROR while OCR retains its specific completeness code.
11. `20261017000500_paper_upload_recovery.sql`: service-verified upload/missing-object recovery on the same canonical session, without lifetime reset or overlapping active transfers.
12. `20261018000100_progress_analytics.sql`: user-scoped, RLS-protected, set-based progress aggregation and a private server clock.
13. `20261018000200_progress_verified_timing.sql`: canonical receive-time simulation analytics, excluding unverified elapsed telemetry without changing prior APIs.

Seed remains exactly the original 20 `diagnostic-v1` words, with 15 seconds, 2000 ms grace, 280 code points and safe feature/quota defaults. No accounts, admins or payment offers are seeded. WAT configuration is enabled; OCR, feedback, payments and beta remain disabled.

## Contract decisions and limitations

- API v1.1.0 gives one lifetime **authenticated diagnostic session**, not unlimited sessions with a single report. A new key/device/mode resumes the same unfinished writable free session. Completion or expiry cannot reset that claim. Paid or enabled-beta access allows further sessions; starting/finishing/importing consumes no report quota.
- There is no published practice set in Phase 1 seed. `kind=practice` returns `FEATURE_DISABLED` until trusted configuration publishes one; no new word bank was invented.
- The contract does not give a dedicated error for a second active paid/beta session. The existing global `SESSION_STATE_CONFLICT` code is used. Expired in-progress rows cannot be abandoned through any Phase 2 route; a future trusted recovery/abandon flow must resolve them without inventing a new state.
- Free-demo resume items include the original timing plus `answer`, `locked`, `completed`, and `time_used_ms`, as required by the specification's resume narrative.
- Acceptance uses database statement receive time, never client timestamps. `client_elapsed_ms`, when supplied, remains response-time telemetry; absent simulation telemetry is derived from server receive time and capped at 15000 ms. Imported timing is always `client_reported`.
- Natural finish before all simulation windows close reports actual completion and sets `ended_early`; future unattempted windows remain unattempted. Closed windows become blanks. No fabricated answers or future completion times are accepted.
- Protected columns reserve trusted technical recovery on the same free session. Phase 2 exposes no recovery endpoint or worker. It never grants a fresh demo after an alleged client failure.
- Payment/offer endpoints, admin screens, privacy export/deletion workers, OTP delivery and frontend integration remain deferred. Unconfirmed paper report requests return `SESSION_STATE_CONFLICT`; confirmed paper uses the same Phase 3 report implementation.

## Feedback jobs and quotas

The report POST commits a quota reservation and queued job before any provider call. The isolated `feedback-worker` function claims due work using a server-only secret, rechecks current consent/kill switches, sends only quoted ordered word/answer pairs, validates structured output and persists exactly 20 items atomically. PostgreSQL derives scores from 1-5 rubric ratings; blanks produce null scores and do not affect averages. Report retrieval includes the exact practice-only disclaimer. Provider/model/prompt/rubric versions are retained; raw output, prompts and provider error bodies are not stored or logged.

One free report belongs only to the canonical authenticated demo. Active beta/paid accounts receive three report slots per rolling 24 hours. Reserved and consumed slots count; terminal failures release reservations. Retries and duplicate clicks preserve the same reservation. Technical recovery reuses the failed session. New report requests require current explicit AI-processing consent; previously generated reports remain readable after withdrawal or entitlement expiry.

The worker uses five-minute processing leases, stale-lock recovery and at most two attempts per job with bounded exponential retry. A server-only daily provider-attempt cap defaults to 100. Worker invocation must be scheduled by trusted infrastructure for unattended processing; no hosted scheduler is deployed in this phase. See `supabase/functions/_shared/feedback/README.md` for invocation, local mocks, recovery and optional manual real-provider smoke testing.

The root/backend empty environment examples include `GEMINI_API_KEY`, `GEMINI_MODEL`, `GEMINI_PROMPT_VERSION`, `GEMINI_REQUEST_TIMEOUT_MS` and `QIYADAT_WORKER_SECRET`. No model is silently substituted. The specification's `gemini-3.5-flash-lite` is documented by Google as supporting text, structured output and a free tier (verified 2026-10-16). Free-tier prompts/output may improve Google products, which must be disclosed in the current AI-processing consent mechanism. Automated tests use only synthetic local mocks.

The workspace is connected to `https://github.com/rafiullahshaikh/ISSB-APP` on `main`. Offline checks scan source for recognizable secrets, exclude ignored local CLI state, and compare original migration, specification and HTML hashes. Review `git status` before every commit; local runtime artifacts and real environment files must remain ignored.

## Paper OCR and cleanup

See `supabase/functions/_shared/paper/README.md` for the approved relay design,
server-only Vision OAuth configuration, exact private paths, quota/worker rules,
mapping, candidate confirmation, deletion and optional real-provider smoke test.
The root/backend empty environment examples list all new variable names.
`npm run worker:paper` invokes only the fixed local OCR and cleanup workers with
the private worker secret. Production must schedule both; nothing hosted is
linked, configured or deployed here.

Run `test:ocr:unit`, `test:ocr:worker`, `test:paper:storage`, `test:vision:mock`,
`test:paper:cleanup` and `test:ocr:http` through npm. No packages or real Google
credentials are required. The HTTP runner uses disposable local Auth accounts,
real private Storage and synthetic Vision/Gemini servers. It tests immediate
deletion and temporarily unavailable Storage, then restores the container/flags
and removes fixtures. All HTTP suites share the stack and must run serially.

## Progress Analytics

`GET /progress` accepts only `range=7d|30d|90d|all`,
`compare=none|previous_period`, `practice_mode=all|training|simulation` and
`response_mode=all|typing|paper`. Defaults are 30d, previous_period and both
mode filters all. No entitlement, AI consent or enabled provider is required to
read owned activity. Unknown, repeated and unsupported options return the
standard VALIDATION_ERROR. Responses are private/no-store with request IDs.

The user-scoped `qiyadat_progress` RPC derives auth.uid() and respects existing
RLS. It accepts no owner, timezone, clock or raw SQL. It reads one consistent
database snapshot, returns only Section 8 fields and makes no provider request.
No new environment setting or dependency is required.

Range boundaries use profile-local calendar dates, including today, converted
independently to UTC for DST correctness. Completion is completed word positions
over the immutable delivered words, not finished-session percentage. Imported
simulation timing never enters verified simulation averages. Typed server
simulation uses authoritative receive time, not a client elapsed claim, capped
at 15 seconds; paper confirmation time is never a response timer. Missing scores
and timing remain null. Streaks use distinct completed local dates and may end
yesterday; mode filters apply, but the selected range does not truncate a streak.
Weekly windows are independent of range; compare=none returns explicit null.
Weaknesses must recur in two selected ready reports; directions compare weekly
occurrence rates, and labels/drills reuse the latest eligible stored report.
See PHASE5_NOTES.md for lifecycle, timing and insufficient-evidence decisions.

```powershell
npm.cmd run test:progress:unit
npm.cmd run test:progress:http
```

The HTTP harness uses only the existing cached local runtime, real local Auth,
RLS and disposable synthetic fixtures. A private analytics clock is fixed for
the test and restored in finally; no public clock override exists. Run it
serially with all other HTTP suites. It checks application runtime logs in
memory and deletes fixture reports before deleting Auth accounts and dependent
sessions/jobs. No Gemini or Vision configuration is needed for progress.
