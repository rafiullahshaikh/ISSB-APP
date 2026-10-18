# Phase 5 progress analytics - 2026-10-18

Implementation is in progress. API_SPEC.md v1.1.1 Section 8 remains unchanged.
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
- Timing is response-weighted across completed positions with non-null stored
  time_used_ms. Imported simulation timing is excluded. Imported training is
  training telemetry. Legitimate paper timing remains; missing timing is null.
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
