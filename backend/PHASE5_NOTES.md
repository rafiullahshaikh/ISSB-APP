# Phase 5 progress analytics - 2026-10-18

Phase 5 is complete locally. API_SPEC.md v1.1.1 Section 8 remains unchanged.
Phase 4 evidence: 694 database assertions, 121 Node tests, 69 HTTP tests.
All fourteen previous migrations and seven unrelated deletions are preserved.

## Audit and Semantics

- Ranges and trend dates use immutable session started_at, matching history.
  Convert local calendar boundaries through profile IANA timezone independently,
  not fixed UTC hours. Return equivalent RFC 3339 UTC strings and timezone.
- Completed practice has finished_at and a post-finish state other than failed.
  Paper awaiting upload/OCR is finished practice, not confirmed answer text.
  In-progress/failed activity is not a completed session or trend.
- Presented words are session_size (the immutable delivered 20-word snapshot).
  Completed words use response.completed; answers use status=answered, never OCR
  drafts. Completion percent is completed words / presented words, not finished
  sessions / sessions, consistent with api_statistics and Section 8's example.
- Timing is response-weighted across completed eligible positions. Imported
  simulation timing is excluded. For server typed simulation, canonical
  received_at minus the position opening time is authoritative and capped at
  15 seconds: stored client_elapsed_ms/time_used_ms telemetry cannot override
  it. Server-generated blank timer durations remain eligible. Paper confirmation
  timestamps are not per-word timers; only legitimate stored paper timing is
  retained. Imported training remains telemetry, and missing timing stays null.
- Ready reports are final feedback_reports joined to a succeeded feedback job.
  Reuse deterministic overall_score. Processing/failed jobs have no final report.
  Public decimals round once to one decimal. Missing timing/score stays null.
- Trends include completed sessions in range, ordered local date, started_at,
  UUID. Streak counts distinct completed local dates across filtered history,
  independent of range, ending today or yesterday; a full missed day breaks it.
- Weekly comparison is independent of range: current seven local dates versus
  preceding seven. compare=none returns weekly_comparison=null and skips that
  object aggregation. Required weak-area directions still use weekly rates.
- Weakness codes require two distinct selected ready reports, once per report.
  Latest generated_at/report UUID supplies label and summary.next_drill.code.
  Compare occurrences / all filtered ready reports per weekly window; no
  evidence in either window means stable. Sort count descending then code.
- all starts at the earliest matching session before tomorrow's local midnight;
  empty all starts at today's local midnight. Imported dates remain activity
  claims, never newly server-verified simulation evidence.

## Architecture

Use a SECURITY INVOKER, empty-search-path RPC with only the four query options,
auth.uid() and existing RLS. No actor, timezone or clock input is exposed. A
single set-based query uses existing statistics definitions without per-session
N+1 RPCs, provider calls or report-score recalculation. Add no index without
query-plan evidence. No new environment setting or dependency is needed.

A private clock normally returns statement_timestamp. SQL tests replace it in
a rollback transaction; the serial HTTP harness temporarily replaces only this
local analytics clock and restores its exact definition in finally. It is not
exposed by PostgREST and candidates cannot set it via an API input.

## Database Checkpoint

Clean local reset applied all fifteen migrations with exit 0. The database suite
passed 780 assertions (694 preserved + 86 progress), before the router was wired.
A rollback-only 1,000-session / 20,000-response fixture measured the full all-range
RPC at 454.020 ms locally. The representative join used the existing unique
session/position index; a session scan was expected when the fixture owned the
entire table. No speculative index was added. The benchmark fixture rolled back.

The database initially needed filesystem recovery after an unclean local stop;
its startup log reached ready-to-accept-connections before the successful reset.
No Docker/WSL configuration change or missing-runtime download was performed.

The API route uses the existing verified Auth context and its separate
user-scoped client. Strict query parsing rejects unknown, repeated and unsupported
values before the analytics RPC. Dependency errors on GET /progress map to the
documented INTERNAL_ERROR without diagnostics; unrelated routes keep their
existing error behavior. The new route/unit checkpoint passed 27 Node tests.
All nine unit package commands then passed: 148 tests, comprising 121 preserved
and 27 progress tests. Required full database lint has only the known Phase 1
unused method parameter warning. Database checkpoint 72236b5 is pushed to main.

The initial HTTP run stopped on a fixture expiry constraint: JavaScript Date
truncated microseconds when adding 30 minutes to a synthetic start timestamp.
HTTP fixtures now use millisecond instants; SQL tests retain exact microsecond
boundary coverage. The failed run removed its accounts and restored the clock;
no production calculation or migration needed changing.

A final audit found Phase 2 deliberately retains client elapsed telemetry even
on server sessions. The additional forward-only progress timing migration uses
canonical typed receive times instead of trusting that telemetry for simulation
analytics. It preserves Phase 1-4 writes/history/statistics and never derives
paper timing from a later OCR confirmation. New SQL cases cover inflated client
times, grace capping, unverifiable telemetry, paper nulls and long streaks.

One development HTTP run saw a gateway restart and a dependency timeout while
shared documentation was being edited under the local function watcher. Health
and non-sensitive database wait checks were normal, no service had OOMKilled,
and fixtures/clock were cleaned up. With files frozen the full 30-case run passed
without retries. The final timing case expands this to 31; final verification
results supersede these development runs. Source files must stay frozen while
HTTP suites are running to avoid development reload interference.

The final clean reset applied all sixteen migrations, exit 0. All 788 database
assertions passed (694 preserved + 94 progress), and full lint retained only the
known Phase 1 unused method parameter warning. One preceding reset exited before
initialization during a local restart; no source changed, PostgreSQL was healthy,
and the retry with the temporary Edge Runtime stopped passed. A final rollback
benchmark with 1,000 imported simulation sessions and 20,000 responses completed
the all-range RPC in 1030.980 ms. No extra index was justified or added.

## Final Acceptance

The final package-command matrix passed all 148 Node unit tests and all 100 HTTP
tests: 31 progress, 20 preserved API, 18 feedback and 31 paper/OCR. No tests were
skipped. Progress, feedback and paper runtime privacy checks passed. The progress
harness restored the exact normal clock definition. Final inspection found zero
Auth users, sessions, responses, reports/items, jobs, paper uploads and paper
Storage objects; normal feature flags remain false. Provider safety ledgers may
retain synthetic dispatch counts by design, not candidate data or queued work.

No real Gemini, Vision, payment or hosted Supabase service was used. GitHub
pushes are the only hosted project updates. No dependency/runtime was installed
or updated, no Docker/WSL configuration changed, no new environment setting was
added, and no frontend, payment, admin or privacy feature was implemented.
The fourteen Phase 1-4 migrations, binding specification and original frontend
hashes pass preservation checks. Seven unrelated deletions remain unstaged.

Database checkpoint 72236b5, API checkpoint 2f8a012 and timing safeguard 11451d5
were pushed independently. The final HTTP/documentation checkpoint follows them.
See VERIFICATION.md for the exact commands and results. No blocker remains.
