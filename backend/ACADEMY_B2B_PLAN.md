# Qiyadat academy subscription plan

Planning snapshot: 2026-10-19. This is a proposal, not an implemented API or a
replacement for API_SPEC.md. No application code, migration, payment work or
existing verification baseline is changed by this document.

## Recommendation

Build an academy edition around the existing WAT engine. Start with a small
paid pilot, manual academy onboarding and manual subscription renewal. Keep
the personal student flow working. An academy subscription sponsors access;
it does not give its owner platform administrator privileges.

Because outreach starts from scratch, first use a clearly labelled synthetic
academy demonstration to test the offer with five owners. Get evidence of a
real checking/tracking problem and willingness to pay before building optional
features. A demonstration is not evidence that academy access works in production.

The first paid pilot must support this complete journey:

1. Platform operator creates an academy and activates its paid period.
2. Owner signs in, creates a batch and invites students.
3. Student signs in individually, accepts academy sharing and joins the batch.
4. Student completes typed WAT practice in the academy context.
5. Owner sees batch participation and opens the shared answers/results.
6. Eligible student requests an AI report within the academy allowance.
7. Both sides can see subscription expiry and remaining allowance.

## What the repository actually has

| Area | Evidence | Consequence |
|---|---|---|
| Backend | Supabase Auth, PostgreSQL/RLS, Edge Function router, feedback and OCR workers | Extend this architecture; no backend framework replacement is needed. |
| Verified checkpoint | backend/VERIFICATION.md records phases 1-5 complete locally | This is recorded evidence, not a fresh test run for this plan. |
| Phase 6 | Payment SQL, router integration and tests exist; PHASE6_NOTES.md says verification is in progress; working tree has additional payment edits | Preserve and checkpoint this work before academy implementation. Do not describe all of phase 6 as verified. |
| Frontend | Four root HTML pages use inline JavaScript and localStorage; no connected sign-in/API flow | Connecting the student journey is essential work, separate from adding academy screens. |
| Personal access | private.api_has_access checks founding_30d or enabled beta; account context reports personal entitlement | Academy access needs a distinct, scoped authorization decision. |
| Payments | Approval inserts a founding_30d entitlement for the payment's user | Paying as an owner would currently unlock that owner's personal account, not an academy. |
| Reports | Per-user three-per-rolling-24-hour quota, durable reservations, retries and a global provider-attempt cap | Add organization-period accounting without removing the existing safeguards. |
| Progress | qiyadat_progress derives the caller from auth.uid() and reads that caller's records | It cannot be turned into instructor analytics merely by passing another student's ID. |
| Privacy | Owner-only RLS; privacy endpoints specified but absent from the router | Sharing rules and functioning export/deletion need a release gate before a real student pilot. |
| Content | Only diagnostic-v1 is seeded; only 20-word sessions are supported by backend constraints | Publish reviewed practice content before selling repeated practice. |
| UI mismatch | Browser prototype permits 20/40/60/80/100 words; backend only accepts 20 | Connected pilot must use 20-word sets. Longer tests are a separate contract change. |
| Contract | API_SPEC.md section 15 excludes organization/team accounts | Explicitly revise the contract for academy scope before implementation. |
| Guard scripts | verify_repository.py fixes original HTML/spec/migration hashes and the original 22-table foundation; verify_frontend.cjs checks four root pages | Extend checks deliberately for the academy edition and connected UI; do not hide failures by refreshing every baseline. |

The working tree also has seven pre-existing tracked deletions and incomplete
payment changes. Leave those intact. Do not restore, stage, overwrite or commit
them as part of an academy planning change.

## Initial offer to test

Illustrative founding pilot, subject to cost measurement and owner interviews:

- PKR 12,000 for one clearly dated monthly service period, paid in advance.
- One owner account that also acts as the instructor; up to 30 active students.
- Basic batches, invitations, typed WAT practice, participation and shared results.
- Up to 120 successful AI reports per paid period, with at most four per student
  in that period and the existing per-user daily protection retained initially.
- An active-seat cap plus a distinct-students-served cap per billing period,
  initially both 30. Removing one student must not permit unlimited seat cycling.
- Reasonable server-enforced session/request limits; do not advertise unlimited use.
- Paper OCR is excluded from the academy pilot at both UI and server levels.
- Manual onboarding and renewal; no automatic collection or custom installation.

These are proposed limits, not a proven price or margin. Calculate:

    contribution = collected subscription revenue
                 - AI provider charges, including retries and failures
                 - hosting, storage, email and payment costs
                 - support/onboarding cost

Measure real report usage and actual costs before promising larger allowances.
An owner's plan screen should show seats, students served, report allowance,
period dates and renewal status in plain language.

## Backend changes

### 1. Add organization records without changing student ownership

Introduce versioned migrations for these responsibilities; final table names
and exact columns belong in the contract/schema design:

- Academies: name, timezone, active/suspended status and feature controls.
- Memberships: academy, user, owner/student role, status and join/leave history.
  An instructor role can be added when a customer needs multiple staff accounts.
- Invitations: intended email/role, hashed single-use token, expiry and revocation.
- Batches and batch membership: academy-bound cohorts with scoped student lists.
- Subscription periods: academy, plan snapshot, exact start/end, limits, status,
  amount/currency and a unique verified billing event.
- Session context: immutable academy, batch, membership episode and funding
  source linked to an existing student-owned session. Personal sessions have no
  academy context.
- Academy report reservations: period, member, session/job and
  reserved/consumed/released state, linked to the existing usage reservation.
- Academy audit events: grants, renewals, invitations, removals and scope changes;
  store event identifiers, not copied answers or tokens.

Use composite foreign keys/constraints to reject cross-academy batch/session
links even when an application check is missed. Add indexes for academy, batch,
student, date and status queries. New tables get RLS/default-deny grants.

Keep wat_sessions.user_id and all existing response/report ownership intact.
Do not add a general instructor-read policy to every personal-data table.

### 2. Define academy access as separate from personal paid access

- Keep existing personal routes, request fields and behavior compatible.
- Add academy-context endpoints under /v1/academies and a separate account
  academy-context read; keep /me's current personal entitlement truthful.
- Add an academy session-start route that verifies active membership, sharing,
  batch, subscription period, limits and allowed practice settings in one
  transaction. It creates the normal WAT session plus its immutable context.
- Extract only the necessary internal start/access decisions so academy and
  personal entry points share timing, answers, finish and state validation.
  Do not maintain two copies of the WAT engine.
- Existing answer/finish/read endpoints can continue to serve the authenticated
  session owner. Report requests inspect stored context to choose the correct
  funding/quota path, regardless of which URL a caller tries.
- An academy-sponsored session cannot claim the lifetime free demo, silently
  charge personal access, switch academy or change funding after it starts.
- Personal purchases and demos continue independently. Leaving an academy does
  not remove a student's own historical results or reset their lifetime demo.

Only the authenticated actor supplies authority. A submitted academy ID, profile
role or editable user metadata never grants membership or staff permissions.

### 3. Create narrowly scoped instructor reads

Add paginated academy roster, batch participation, shared session detail and
shared report endpoints. Every operation checks the current actor's membership
and the target's academy/session context in the database as well as at the API.
Prefer narrowly guarded service RPCs with explicit authorization and response
allowlists, following the existing payment-admin pattern. Keep direct personal
table reads restricted to the student.

Instructor visibility requires an active staff membership and the student's
current sharing permission for that academy membership episode. A batch move
does not rewrite old session context. Removal/withdrawal immediately blocks new
instructor reads; rejoining does not automatically reshare an earlier episode.
Already viewed information cannot be recalled, which the sharing notice must explain.

Personal sessions before joining, unshared practice, another academy's sessions,
payment references, raw images/OCR drafts, job internals and safety flags are
outside the instructor projection. Shared typed answers and selected practice
feedback are disclosed clearly before joining. AI-processing consent remains
an individual, separate decision.

Do not call the current personal progress function once for each student.
Build a set-based, academy-scoped aggregation using its verified metric rules:
completion, activity, comparable ready-report scores, timing trust and missing
values. Use academy timezone for batch periods. No score is shown as zero when
there is no scored report. Distinguish no activity from no AI allowance.

### 4. Add subscription and quota accounting

Keep the existing personal payment endpoints personal. Initially, a platform
operator verifies an academy transfer and records one idempotent academy billing
event/period through a restricted operation. Owners can read their academy plan
but cannot grant access, change limits or approve payments. An invoice UI and
owner payment-submission flow can follow later.

Store a plan snapshot per period so a later price change does not rewrite an
existing purchase. Define monthly calendar boundaries in Asia/Karachi, with
half-open timestamp ranges; display exact dates. Do not label a fixed 30-day
grant as a calendar month. Early renewal queues the next period without starting
it twice or resetting the current allowance.

Before queueing a report, atomically reserve the existing user slot AND the
academy-period/student-period slot. Concurrent requests for the last slot must
not exceed the limit. Use one documented lock order compatible with existing
profile/session/job locks across enqueue, completion, failure and removal paths.

Duplicate requests reuse one job and reservation. Success consumes once;
terminal failure releases customer allowance once. Actual provider attempts,
including retries and failed outputs, remain counted against spend controls.
Reservations retain the original period across renewal; retries never move
charges into another period. Cancellation and account deletion must not reset
academy-wide usage: retain minimal non-content accounting/tombstones as needed.

The worker must recognize the stored funding context and enforce academy
disable/suspension before dispatch. Define this policy: already reserved work
may finish after ordinary subscription expiry; suspension, disabled account or
withdrawn AI consent cancels undispatched work and releases allowance. Keep
current worker leases, fencing, idempotent completion and global kill switches.
Define the boundary for a provider call already in flight rather than promising
that a remote request can always be recalled.

Track per-academy provider attempts and enforce a conservative attempt budget
in addition to report credits and global provider caps. No provider-rate or
free-tier assumption should be the basis for selling unlimited reports.

### 5. Handle lifecycle and content before a pilot

- Publish reviewed immutable 20-word practice sets through trusted configuration;
  the browser's local word bank is not already a published backend practice set.
- Test the latest-config rule in api_start_session when publishing a new version.
  The initial pilot starts the current version. Later assignments that pin older
  versions need explicit validation/API support, not removal of version checks.
- Resolve the documented expired in-progress-session blockage through a defined
  expiration/abandon/recovery contract and matching state guards. Preserve the
  30-minute write TTL, accepted timings and lifetime-demo claim.
- Invitation redemption is bound to verified identity, sharing acceptance and
  capacity, transactionally. Prevent replay, expired tokens, email mismatch,
  role tampering and concurrent oversubscription. Do not log invitation tokens
  or place them in persistent browser storage; strip them after redemption.
- Prevent the last owner from leaving without an explicit transfer/operator path.
- On expiry, prevent new sponsored practice/report reservations and keep the
  student's own saved results readable. Existing instructor reads stay available
  only while memberships/sharing are active and the academy is not suspended.
- Extend export/deletion to memberships, invitations, session context and academy
  reads. Delete personal content and invalidate access promptly while preserving
  only minimal billing/usage/audit accounting. Choose and disclose retention dates.

## Frontend changes

Retain the current visual style. Keep vanilla HTML/JavaScript unless a concrete
need justifies a framework. Initially add a connected edition under app/ with
shared assets, leaving the root prototype intact for regression comparison.
Give the prototype a clearly labelled demo entry point when publishing the site.

| Screen | Required behavior |
|---|---|
| Academy landing/demo | Explain instructor time savings, show labelled sample data and a clear demo/contact action; no unbuilt feature claims. |
| Sign-in/join | Individual email OTP, invite acceptance, academy name and sharing notice; safe handling of expired links. |
| Student home | Current academy/batch, start practice, own results, AI consent and remaining allowance. |
| Practice | Server-created 20-word session, server config, normal answer saves, reload/resume, truthful save status and timing. |
| Results | Fetch the session/report by ID; queued/processing/failed/ready states, safe polling and retry messages. |
| Student progress | Fetch history and /progress; keep server-verified and imported timing distinctions. |
| Owner dashboard | Batch roster, invites, participation, inactive students and shared results; mobile-friendly and paginated. |
| Plan | Exact subscription dates, seats/students served, reports used/remaining and manual renewal instructions. |

Use shared auth, API/error handling and safe rendering modules. Only the public
Supabase key reaches the browser. Handle expired authentication, duplicate
clicks, slow requests, offline state and retryable errors consistently. Clear
account-specific caches on sign-out/account switch; never present one student's
local history to the next user of a shared academy computer.

localStorage is no longer authoritative for paid access, score, completion,
membership or saved sessions. Do not silently import prototype history: it can
have unsupported word counts, unmatched sets and unverifiable timing. Any later
import remains explicit and passes the existing backend contract.

The existing prototype's clear-history buttons cannot represent cloud deletion.
Connected pages must use a documented server operation or omit that action
until it exists. Do not display a local deletion as deletion from the account.

Server-side roles/permissions remain decisive even if somebody opens an owner
page directly or edits the frontend. Academy responses are private/no-store;
all text renders without interpreting user-supplied HTML.

## Implementation sequence and acceptance gates

| Step | Deliverable | Must pass before proceeding |
|---|---|---|
| 0. Checkpoint | Preserve phase 6 changes and deleted files; finish/review payment verification separately | Existing failures documented; stable personal-backend checkpoint, no mixed academy/payment patch. |
| 1. Demonstrate and specify | Labelled synthetic owner walkthrough, interview findings, revised academy contract and plan limits | Clear first buyer workflow and data-sharing policy; no changes to protected hashes just to silence checks. |
| 2. Connect student flow | app/ auth, typed practice, session results, feedback and progress using existing backend | Real local authenticated end-to-end flow, reload, expiry, retries and account-switch isolation. |
| 3. Add academy foundation | Memberships, invites, batches, manual periods, scoped start and access | Migration tests, role/tenant isolation, seat races and unchanged personal flow. |
| 4. Add usage and owner view | Atomic period reservations, worker integration, instructor projections and batch analytics | Quota races, duplicate callbacks, retries, renewals, revocation and cross-academy denial tests. |
| 5. Release a small pilot | Privacy lifecycle, reviewed practice sets, hosted setup, worker/cleanup scheduling and owner onboarding | Local/staging checks, real provider smoke/cost measurement, email delivery and restore/recovery checks; one academy first. |

Steps 3 and 4 should be delivered as small independently reviewed migrations/API
changes, not one large schema-and-UI replacement. All academy capabilities start
behind an off-by-default academy feature flag. Stage 1 demonstrations may be
used for outreach while later implementation continues.

## Verification required for the implementation

This planning task does not reset databases, call providers, deploy or certify
the current uncommitted payment work. For the actual implementation:

1. Re-establish the current database, unit, HTTP and frontend baseline, including
   phase 6's new suites. Keep historical migration checksums unchanged.
2. Test every migration on a clean local database and an upgrade from the
   checkpoint. Use synthetic accounts and two unrelated academies.
3. Test owner A against academy B through every read/write endpoint and direct
   database API. Test students, revoked staff, revoked students, disabled users
   and malformed/forged contexts. Include pagination cursors and aggregate leaks.
4. Test parallel invitation acceptance for the final seat and reports for the
   final credit, duplicate clicks, lost acknowledgements, worker retries,
   failures, cancellation, period boundaries and renewal.
5. Run existing personal session, demo, consent, feedback, OCR, progress and
   payment regression suites. Academy-disabled behavior must preserve personal
   access and prevent new academy-sponsored work.
6. Exercise browser flows on mobile/desktop: OTP, reload/resume, network failure,
   signed-out redirect, shared-device account switching, report polling, owner
   navigation, removal and expiry. Syntax/link checking alone is insufficient.
7. Extend verification scripts for app/ files and new academy schema/contract
   checks. Keep original prototype/foundation checks separately; avoid assertions
   that forever require the whole evolving schema to have exactly 22 tables.
8. Before inviting real students, verify hosted RLS, exact CORS/redirect origins,
   scheduled workers/cleanup, consent and sharing text, export/deletion, and
   real provider cost/latency on synthetic content. Record results honestly.

Rollback initially means disabling new academy enrollment/work via flags and
returning to the stable frontend entry point. Do not drop academy tables or
discard paid-period/usage records. Restore from a tested backup only through a
separately reviewed recovery procedure.

## Defer until customers demonstrate a need

Custom domains/white labelling, separate deployments per academy, multiple staff
roles, automatic payments, complex invoices, WhatsApp integrations, native apps,
leaderboards, PDF certificates, expanded ISSB modules and OCR add-ons.

Assignments with due dates, pinned set versions and instructor notes are useful
follow-ups. Initial batches can use a shared current-practice link; do not claim
missing/overdue assignment tracking until those records and rules exist.

The product promise for the pilot is: an academy can organize students, see
shared WAT practice and use a controlled amount of AI feedback in one place.
The first commercial success criterion is a paying owner using that workflow
with students and choosing to renew after seeing the results.
