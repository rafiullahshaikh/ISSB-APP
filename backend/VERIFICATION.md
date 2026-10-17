# Phase 4 prerequisite status - 2026-10-17

**Phase 4 is in progress, not complete.** The user approved a protected upload
relay after the expiry investigation. API_SPEC.md v1.1.1 records the authorized
contract change before implementation. See `PHASE4_NOTES.md`.

`node --experimental-strip-types backend/scripts/probe_upload_expiry.ts`
passed with exit 0. The local characterization verified the standard token's
7200-second lifetime, its bypass of an inactive authorization row, the preserved
S3 owner-upload RLS denial, and private read denial. These are blocker findings,
not passing Phase 4 upload/OCR tests. No real provider was called.

Final inspection found zero probe Auth accounts, zero paper upload rows and
zero paper Storage objects; OCR/feedback/payments/beta remained disabled.
No migration, API route, worker, Storage policy, Docker/WSL configuration or
hosted configuration was changed. The full clean-reset/HTTP matrix below is
prior Phase 3 evidence and has not been rerun for Phase 4 completion.
Unrelated pre-existing Git deletions remain untouched and unstaged.

Additional preservation checks in this investigation:

| Command/check | Observed result |
|---|---|
| Installed CLI `test db` | Exit 0, `Files=3, Tests=580`, all successful. |
| Direct Node test runner for `api_unit_test.ts`, `feedback_unit_test.ts`, `worker_test.ts` | Exit 0, 62 passed, 0 failed, 0 skipped. Corresponds to 22 API + 34 feedback + 6 worker tests. |
| `python backend/scripts/verify_repository.py` | Exit 0, all offline checks passed. |
| `node backend/scripts/verify_frontend.cjs` | Exit 0, four preserved scripts parse and local links resolve. |
| Installed CLI `db lint --local --level warning` | Exit 0 but emits stock `extensions` pgTAP diagnostics plus the known application warning; not a clean whole-database lint result. |
| Installed CLI `db lint --local --schema public --schema private --level warning` | Exit 0. Only `private.payment_transaction_hash` has its previously documented unused `method` parameter warning. |
| `git diff --name-only -- supabase API_SPEC.md index.html wat-practice.html wat-results.html wat-dashboard.html .env.example backend/.env.example` | Empty: no runtime/schema/spec/frontend/environment-example changes. |

The default lint's stock pgTAP diagnostics include missing test-session temporary
relations/sequences, legacy PostgreSQL compatibility branches and type/dynamic
SQL warnings inside extension functions. They are not application functions and
were not patched. The explicitly scoped application lint isolates the existing
warning. Three npm launcher processes stalled without test output and were
stopped; the identical underlying Node test files then passed directly using
`node --experimental-strip-types --test-isolation=none --test` followed by the
three file paths. No npm install or package update was performed. Clean reset
and HTTP regression reruns remain unperformed in this blocked prerequisite
investigation; Phase 4 OCR/worker/cleanup suites do not yet exist.

---

# Phase 3 verification status - 2026-10-16

**Phase 3 is complete locally.** A finished typed session can reserve quota,
create a durable feedback job, run through the protected worker and local Gemini
HTTP mock, and retrieve a complete practice report. All preserved suites and new
feedback suites pass. No hosted project was linked or deployed and no real
Gemini request was made.

| Command/check | Assistant-observed result |
|---|---|
| `node 'C:\Users\windows10\node_modules\supabase\dist\supabase.js' db reset --local` | PASS, exit 0. Clean database recreation applied all nine migrations and original seed. The six Phase 1/2 migrations remain unchanged. |
| `node 'C:\Users\windows10\node_modules\supabase\dist\supabase.js' test db` | PASS, exit 0. `Files=3, Tests=580`, all successful: 505 preserved assertions plus 75 feedback assertions. |
| `node 'C:\Users\windows10\node_modules\supabase\dist\supabase.js' db lint --local --level warning` | PASS, exit 0. No new warnings or errors. The existing unused `method` parameter in `private.payment_transaction_hash` is the sole explained warning. |
| `npm run test:api:unit` | PASS, exit 0. 22 tests passed, 0 failed; 2.267 seconds. |
| `npm run test:api:http` | PASS, exit 0. All 20 preserved HTTP tests passed, 0 failed; 27.728 seconds. |
| `npm run test:feedback:unit` | PASS, exit 0. 34 tests passed, 0 failed; 2.773 seconds. Includes mocked provider schema failures, refusal, quota, actual request abort, partial/all-blank scoring, privacy and prompt injection. |
| `npm run test:feedback:worker` | PASS, exit 0. 6 tests passed, 0 failed. Covers claims, authorization, retries, lost completion acknowledgement, empty queues and safe logs. |
| `npm run test:feedback:http` | PASS, exit 0. 18 tests passed, 0 failed; 17.011 seconds. Real local Auth/PostgREST/Edge API and worker plus a synthetic HTTP Gemini provider. Runtime log privacy assertion passed. |
| `python backend/scripts/verify_repository.py` | PASS, exit 0. Includes immutable specification, all six original migrations and four HTML files, restricted grants, security matrix, seed/config, source credential scan and empty environment examples. |
| `node backend/scripts/verify_frontend.cjs` | PASS, exit 0. Four preserved scripts parse and local links resolve. |
| Git | Database step committed as `89d45d7` and pushed to `main`; API/worker/test/documentation step committed separately. Unrelated pre-existing deletions remain unstaged and untouched. |

## Phase 3 verification coverage

The new SQL suite verifies free-demo reservation, three rolling paid/beta slots,
fourth-request rejection, atomic success/failure, duplicate jobs/reports,
twenty persisted items, blank/null aggregates, fixed worker attempts, stale
recovery, worker fencing, quota release, same-demo technical recovery, current
and withdrawn consent, reacceptance, global caps, restricted function execution,
owner RLS and safe trusted-admin job reads. HTTP tests additionally race report
requests with identical and different keys, race paid quota reservations, verify
job polling and exact report envelopes, and reject cross-user access. Imported
free activity is feedback-ineligible; paid legacy typed imports generate reports.

All provider inputs are projected to ordered position, word and quoted answer.
The schema rejects extra fields, invalid positions/ratings/enums/lengths,
unsupported flags, invented evidence and prohibited guidance. PostgreSQL derives
persisted sentence/dimension/overall scores independently from integer ratings.
Provider/model/prompt/rubric versions are stored; raw output, prompts, reasoning
and provider error bodies are neither retained nor returned. Automated tests
require no real provider key. A real-provider smoke test remains optional and
was not run.

## Phase 3 runtime notes and resolved failures

Docker Desktop initially could not start its Linux engine. A normal restart
completed; PostgreSQL then spent about seven minutes syncing its filesystem and
performing recovery. The project's Auth/REST/Storage/metadata containers were
temporarily stopped to reduce reconnect load, then restored. No Docker/WSL
configuration or installed package was changed. Existing Edge Runtime v1.77.1
was reused; no runtime was downloaded.

The Node CLI launcher intermittently stalled. The installed native 2.119.0 CLI
completed the initial reset; the final required Node reset command then passed.
The new HTTP harness uses that same installed executable for reliable local
status/startup and never prints captured key material. Readiness requires the
current synthetic worker secret and healthy API configuration before testing.

Verification found and fixed an insertion timestamp mismatch against the
existing job guard. A deterministic retry fixture was corrected to prioritize
due retries over new queued work. The HTTP fixture helper was corrected for
empty REST insertion responses. Synthetic report children are deleted before
Auth accounts because the existing response foreign key is intentionally
restrictive; this is fixture cleanup, not a new account-deletion worker.

The test runner restores feature settings, deletes its synthetic accounts,
closes its mock/server processes and removes synthetic temporary environment
files. The normal seed keeps feedback, OCR, payments and beta disabled. The
local polling runner is available through `npm run worker:feedback`; hosted
scheduling/deployment is deferred. The contract interpretations and versioned
rubric vocabulary are recorded in `PHASE3_NOTES.md`; API_SPEC.md was unchanged.

An initial GitHub push failed DNS resolution; the retry succeeded. The only
database lint warning remains the Phase 1 payment hash parameter intentionally
reserved for future provider-specific normalization. Phase 4 paper upload,
OCR and candidate confirmation are not implemented. Payment, admin UI,
progress, privacy workers and frontend integration remain deferred.

---

# Phase 2 verification status — 2026-10-14

**Phase 2 is complete locally.** The authenticated API foundation and typed WAT
lifecycle pass a clean rebuild, all database tests, unit tests and local HTTP
integration tests. No hosted Supabase project was linked or deployed.

| Command/check | Current observed result |
|---|---|
| `node C:\Users\windows10\node_modules\supabase\dist\supabase.js db reset --local` | PASS, exit 0. Recreated the local database, applied all three unchanged Phase 1 migrations and all three Phase 2 migrations, seeded `supabase/seed.sql`, and restarted containers. |
| `node C:\Users\windows10\node_modules\supabase\dist\supabase.js test db` | PASS, exit 0. `Files=2, Tests=505`, all successful: 406 preserved Phase 1 assertions plus 99 Phase 2 assertions. |
| `node C:\Users\windows10\node_modules\supabase\dist\supabase.js db lint --local --level warning` | PASS, exit 0. No errors or Phase 2 warnings. One reviewed Phase 1 `warning extra` remains for the intentionally reserved `method` parameter in `private.payment_transaction_hash`. |
| `npm run test:api:unit` | PASS, exit 0: 22 tests passed, 0 failed, duration 2.311 seconds. |
| `npm run test:api:http` | PASS, exit 0: 20 tests passed, 0 failed, duration 47.280 seconds against local Auth, PostgREST, PostgreSQL and Edge Runtime. |
| `python backend/scripts/verify_repository.py` | PASS, exit 0: contract/seed/security matrix, original migration/spec/frontend hashes, safe configuration, source credential scan, environment examples and generated-file ignores. |
| `node backend/scripts/verify_frontend.cjs` | PASS, exit 0: all four preserved frontend scripts parse and local navigation links resolve. |
| Git tracking | PASS: local `main` tracks `origin/main`; verified implementation commits are pushed to `https://github.com/rafiullahshaikh/ISSB-APP`. Pre-existing unstaged deletions of synced project files were deliberately not committed. |

## Runtime notes

The installed Supabase CLI is 2.119.0. Docker Desktop 4.95.0 with engine 29.8.2
was healthy for the final run. The first reset during Docker warm-up lost its
PostgreSQL connection before migrations ran; the retry and final verification
reset both completed successfully. The approved local function serve operation
downloaded only the missing Supabase Edge Runtime v1.77.1 image. No package,
Docker/WSL configuration, project link, hosted secret or hosted deployment was
created.

The CLI-generated local Kong configuration attaches its own wildcard CORS
plugin to `/functions/v1`, which intercepts browser preflights before the
function. The HTTP suite therefore sends CORS preflights directly to the served
function over the existing Docker network. It verifies `204` plus the exact
allowed local origin, and `403 FORBIDDEN` with no allow-origin header for an
untrusted origin. Every other HTTP assertion uses the documented public local
URL. Application code never emits `Access-Control-Allow-Origin: *`.

The gateway converts the function's strong ETag to a weak ETag when gzip is
applied. Conditional configuration requests accept either representation and
return `304`; both forms are covered by tests.

The only lint warning is inherited from Phase 1: the payment hash helper keeps
its `method` parameter in the function signature for future provider-specific
normalization, while the current canonical hash intentionally does not use it.
There are no unexplained warnings.

---

# Phase 1 verification status

## Confirmed local verification on 2026-10-05

The assistant independently completed a **clean local reset and all 406
pgTAP database, RLS, and Storage tests**, with exit code 0. All three
versioned migrations and the seed applied successfully. Phase 1 database
and security verification has passed; earlier runtime blockers below are
historical. No hosted project was linked or deployed.

Commands ran from `C:\Users\windows10\Documents\ChatGPT\ISSB aap`.
The existing Supabase CLI is version 2.119.0, installed at
`C:\Users\windows10\node_modules\supabase\dist\supabase.js`.
No runtime or package was installed during this work.

| Verification command | Assistant-observed result |
|---|---|
| `node 'C:\Users\windows10\node_modules\supabase\dist\supabase.js' db reset --local` | Exit 0 in a terminal/PTY context. Recreated the database, initialized the platform schema, seeded roles, applied migrations 20261002000100, 20261002000200, 20261002000300 in order, seeded `supabase/seed.sql`, and reported `Finished supabase db reset.` No migration warnings or errors were emitted. |
| `node 'C:\Users\windows10\node_modules\supabase\dist\supabase.js' test db` | Exit 0. `All tests successful. Files=1, Tests=406. Result: PASS`. The only NOTICE says pgTAP already exists and is skipped. Fixtures and temporary Storage policies roll back. |
| `node 'C:\Users\windows10\node_modules\supabase\dist\supabase.js' db lint --local --level warning` | Exit 0, no errors. One reviewed warning: unused `method` parameter in `private.payment_transaction_hash`, intentionally reserved for future provider normalization; provider and hash form the unique key. |
| `python backend/scripts/verify_repository.py` | Exit 0. Contract coverage, security matrix, seed/config/constants, restricted grants, test-only Storage deletion override, ignored generated files, empty environment example, credential patterns, and unchanged API/HTML hashes all pass. Final rerun after documentation edits passed. |
| `node backend/scripts/verify_frontend.cjs` | Exit 0. All four inline scripts parse and local links resolve. Final rerun after documentation edits passed. |
| `git status --short --untracked-files=all` | Workspace has no Git metadata; tracked-file verification is unavailable. Nothing was committed. |
| `docker ps`, `docker inspect`, and `docker logs` for `qiyadat-local` only | Confirmed healthy database after recovery, no database-container OOM kill, and successful local startup. Dependent services were temporarily stopped to reduce recovery load, then restored with `docker start`. Final inspection confirmed database, Auth, Storage, gateway and metadata containers healthy; REST was running. |

### Resolved runtime failures and diagnostic checks

Two noninteractive `npx.cmd --offline --no-install supabase db reset --local`
attempts exited 1 before applying application migrations: first `DbSetupError:
error running container: exit 125`, then `EUNKNOWN: unknown error, uv_spawn`.
Docker queries stalled, and PostgreSQL performed a slow filesystem sync after
an interrupted startup. `docker desktop restart` completed successfully. The
existing `.wslconfig` was only read; it was not changed. Windows memory and
disk checks reported about 0.8 GB free RAM and 75 GB free disk at that moment;
subsequent WSL `/proc/meminfo` showed about 2.9 GB available and no swap use.

`npm.cmd config get cache`, `npm.cmd prefix`, executable/shim inspection, and
`npx.cmd --offline --no-install supabase --help` located the already installed
CLI under the user directory. A search for an `_npx` cached executable found
none: this installation is a JavaScript CLI in the ancestor `node_modules`.
Running that same CLI directly with Node in a terminal/PTY context succeeded.
This is a working workaround, not proof of the underlying Windows launch bug.
The successful reset replaces the incomplete states from both failed attempts.

Only this project's five dependent containers were stopped and restored:
`supabase_pg_meta_qiyadat-local`, `supabase_storage_qiyadat-local`,
`supabase_rest_qiyadat-local`, `supabase_auth_qiyadat-local`, and
`supabase_kong_qiyadat-local`. PostgreSQL remained running during recovery.
The stop command emitted a Docker deprecation warning for `--time`; future
commands should use `--timeout`. This was not a database migration warning.

### Remaining verification limits

No runtime prerequisite blocks the database suite now. This workspace is
not a Git checkout, so the assistant cannot prove a tracked-file inventory
or create a reviewed commit. The repository scan found no credential values
or real user data; local CLI state and backups are ignored. Interactive
browser behavior and Storage HTTP signed-token behavior are not claimed:
frontend preservation is verified by hashes, parsing and local-link checks,
and Phase 1 Storage enforcement is tested at the SQL/RLS boundary.

## Historical follow-up before Docker became available (2026-10-05)

The user's supplied October 3/4 verification log reports a successful clean
reset, **406 passing pgTAP tests**, and no lint errors. The only lint warning
is the intentionally unused `method` parameter in the payment hash helper.
Those results are user-reported; the assistant has not independently rerun
the database suite after the remaining cleanup below.

Completed repository cleanup:

- Renamed `[inbucket]` to `[local_smtp]`, retaining the working 5532x ports.
- Added `*.bak` to ignore rules; existing backups are preserved.
- Documented the reduced-service start command, WSL memory settings, local
  ports, test-only Storage deletion override and accepted lint warning.
- Confirmed the explanatory hash-function comment is already present.
- Updated offline checks to recognize the ignored local CLI state and backups,
  verify the configured ports/SMTP section, and prohibit the Storage deletion
  override in migrations and executable Edge Function code.

| Follow-up command | Assistant-observed result |
|---|---|
| `npx.cmd --offline --no-install supabase --version` | 2.119.0, exit 0 outside the sandbox. Inside the sandbox, the CLI cannot write its telemetry file under the user's `.supabase` directory. No install was performed. |
| `python backend/scripts/verify_repository.py` | Exit 0; all offline checks pass, including unchanged HTML/API-spec hashes and credential-pattern checks. |
| `node backend/scripts/verify_frontend.cjs` | Exit 0; all four scripts parse and local links resolve. |
| `docker desktop start` | Desktop process reported already running outside the sandbox; the Linux engine remained unavailable. |
| `docker version` and `docker info --format '{{.ServerVersion}}'` | Client 29.8.1 exists, but the Docker Desktop Linux engine pipe is absent, including outside the sandbox. |
| `docker desktop status` | Could not retrieve engine status. |
| `wsl --list --verbose` | Outside the sandbox, both Ubuntu and docker-desktop are stopped. The sandbox alone reports access denied. |
| `docker desktop restart` | Did not restore the engine during this follow-up. No running backend was detected. |
| `git status --short --untracked-files=all` | No Git repository is present. Nothing was committed. |

**Prerequisite at that time (now resolved):** Docker Desktop needed a running Linux engine.
The cached CLI and project source files are available. A fresh reset/test/lint
run cannot proceed while the engine pipe is missing. No additional hosted
account or secret key is required for Phase 1. The reported successful tests
do not mean the engine is currently running.

No database behavior was changed in this follow-up: changes are local
configuration, test comments, ignore rules, offline checks and documentation.
No hosted project was linked or deployed, no tools were installed, and the
HTML files and binding API contract remain unchanged. Interactive browser
verification is still not claimed. Git initialization/first commit was not
performed; a Git repository is needed only for version-control checks.

## Historical initial verification (before the user's October 3/4 fixes)

The following records the earlier unavailable-runtime state and does not
override the later user-reported reset/test results above. No credentials or
real candidate/payment data were added; SQL fixtures use synthetic data only.

## Commands and results

Commands ran from `C:\Users\windows10\Documents\ChatGPT\ISSB aap`.

| Verification command | Result |
|---|---|
| `Get-Command supabase,docker,psql -ErrorAction SilentlyContinue` | Docker executable found; Supabase CLI and psql not found on PATH. Scoped checks of existing Winget/Scoop/npm executable locations found no Supabase CLI. |
| `docker version` | Client 29.7.2 found; no connection to Docker Desktop Linux engine. Error: `dockerDesktopLinuxEngine` named pipe does not exist. |
| `docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'` | Failed for the same missing engine; no running local database was verified. |
| `supabase --version` | Exit 1: `supabase` command/executable not recognized. |
| `supabase db reset --local` | Exit 1 before execution: CLI unavailable. No migration/seed was applied. |
| `supabase test db` | Exit 1 before execution: CLI unavailable. No PostgreSQL/RLS/Storage SQL test was executed. |
| `supabase db lint --local --level warning` | Exit 1 before execution: CLI unavailable. Migration warning inspection remains blocked. |
| `python backend/scripts/verify_repository.py` | Exit 0. Contract table coverage, migration filenames, RLS/test matrix coverage, restricted profile grant, Auth metadata handling, fixed helper search paths, TOML configuration, every numeric spec constant, 20 seed words, no seeded account/admin/offer, file hashes, frontend syntax/links, empty environment example, credential-pattern scan and generated-data checks passed. This is offline inspection, not SQL compilation or security verification. |
| `node backend/scripts/verify_frontend.cjs` | Exit 0. All four inline JavaScript blocks parse and local HTML navigation links resolve. |
| `Get-FileHash -Algorithm SHA256 -LiteralPath index.html,wat-practice.html,wat-results.html,wat-dashboard.html,API_SPEC.md` | Baseline hashes captured before edits. Offline checker confirms all five files remain byte-for-byte unchanged. |
| `python -c` using `tomllib` to parse `supabase/config.toml` | Passed; local PostgreSQL 17 configuration and seed path parse correctly. |
| `git status --short` and `git status --short --untracked-files=all` | Exit 128: workspace is not a Git repository. Tracked-file/commit verification is unavailable. |
| `python -m http.server 8765 --bind 127.0.0.1` | Temporary local-only preview server started for an attempted browser smoke check; no hosted deployment. |
| Browser `createBrowserTab` for `http://127.0.0.1:8765/index.html`, then `getState` | Both browser-tool calls timed out before returning page state. No interactive browser test passed; syntax/link/hash checks are the verified frontend evidence. |
| Preview server interruption | Temporary preview process stopped after the timed-out browser check; no preview server is intentionally left running. |

The final offline checks must be rerun after any further edit. No browser
end-to-end execution is claimed: unchanged hashes and syntax/link smoke checks
prove preservation and basic validity, not full interactive runtime behavior.

## Exact missing prerequisites

1. An installed Supabase CLI on PATH, supporting the included PostgreSQL 17
   local configuration.
2. A running Docker Desktop Linux container engine. The Docker executable
   exists, but its engine pipe is absent.
3. A real Git checkout for tracked-file and commit checks. No `.git` metadata
   is present in this supplied workspace.

After prerequisites exist, run the clean reset, database tests and warning
checks documented in `backend/README.md`. Resolve any failures, then update
this report with actual runtime output before accepting Phase 1. Do not claim
RLS, migration compatibility, or Storage HTTP enforcement has passed until
those checks run.

## Contract boundary

`API_SPEC.md` was read completely before implementation and remains unchanged.
The former FastAPI plan was replaced by Supabase-first documentation. Backend
v1 supports 20 words even though the unchanged HTML prototype offers larger
local sessions. The seeded diagnostic set uses the first 20 current bank words.

No public endpoint, frontend integration, OCR provider, Gemini adapter, payment
screen, job scheduler, or deployment is implemented. Transactional endpoint
RPCs, real quota allocation/release, job claims/recovery, consent acceptance,
report aggregate scoring, payment decision/entitlement/audit transactions,
image cleanup, export/account deletion workers and signed HTTP URL behavior
remain for later phases. Database indexes support expiry; they do not perform
automatic cleanup themselves.

The later upload phase must resolve Supabase's standard two-hour signed-upload
token lifetime against the spec's 900-second requirement. Phase 1 creates no
signed token and does not change that requirement. Provider-specific payment
separator rules and unspecified abandonment/expiry/retry transitions also need
resolution before their endpoints are implemented. These are documented in
`backend/README.md`; no alternative API behavior was silently introduced.
