# Phase 6 payment implementation

Binding contract: API_SPEC.md v1.1.1 Section 9, unchanged. All sixteen earlier
migrations and the seven unrelated working-tree deletions are preserved.

## Decisions recorded before implementation

- Payment references use NFC and surrounding whitespace trimming, preserving
  case and separators. Reject controls, malformed Unicode and more than 100
  normalized code points. SHA-256 of normalized UTF-8 matches the existing SQL
  helper; provider is the other component of the unique constraint. Plaintext
  never crosses the database RPC boundary.
- AES-256-GCM uses a random 96-bit nonce, 128-bit tag and a versioned bytea
  envelope. Associated data binds provider and reference hash. The base64
  32-byte key is supplied outside the repository/database. Missing or invalid
  configuration fails closed for submission and admin decryption.
- Add a constrained JSON benefits field. Existing offers have no reviewed
  benefits, so null is allowed only for inactive offers. No offer/admin seed.
- Candidate history uses a user-scoped invoker RPC, auth.uid() and existing RLS.
  Service RPCs accept only the Auth-verified actor, enforce service role, use
  empty search_path, and recheck active admin membership inside transactions.
  The admin list alone needs SECURITY DEFINER to project auth.users.email:
  service_role intentionally lacks direct SELECT on Auth's users table. It
  validates service role plus the admin allowlist before a fixed, paginated
  query. No general Auth table grants, dynamic SQL or browser execution are added.
- Lock actor/candidate profiles in UUID order, then admin membership for share,
  then payment. This serializes decisions for a candidate, including different
  payments and admins reviewing each other. Use the latest active paid expiry, including
  queued extensions. Beta never contributes to paid duration.
- Payment submit limit is 5 attempts/minute; admin list and decision limits are
  60/minute, using existing private counters. Valid submission business failures count;
  successful idempotent replays do not. Failed submissions release their key.
  Successful keys follow existing retention (at least 24h, retained until trusted
  cleanup); retries cannot duplicate a payment even after key cleanup.
- Date filters are inclusive lower/exclusive upper; ordering is submitted_at
  descending then UUID descending. Cursors are signed, user/route/filter bound.
  Exact reference search computes hashes, including across all three providers
  when no method filter is supplied; it never decrypts a table to search.
- Notes/messages are trimmed NFC plain single-line text, 1-500 code points.
  Reject markup, URLs, email, common credential/token and pasted transcript
  patterns. This validation cannot prove that arbitrary prose contains no
  personal information; trusted operators must follow the documented policy.
  Neither note nor message is included in logs/audit diagnostics.
  A bounded database substring/hash guard rejects the exact submitted reference
  anywhere in either field, including short/multiword values, without decryption.
  Audit TRUNCATE is also revoked from service_role.
- Existing audit request_id is UUID while API request IDs may have req_ prefix.
  UUID request IDs are retained; other valid request IDs map deterministically
  to a domain-separated SHA-256 UUID for correlation, without schema changes.
- Feature disable blocks offers/new submission, but owned history and admin
  review/decisions remain available for payments already submitted.
- No new public endpoint, provider call, frontend, dependency or deployment.

## Verification

Phase 6 is complete locally. Exact final commands and results are recorded in
VERIFICATION.md; development runs below remain historical evidence.

The first database run caught unauthorized grants on private API validation
helpers and a missing timestamp helper permission in candidate history. The new
history function now follows the established self-contained invoker pattern;
all existing helper grants remain unchanged. The second run passed all 788 prior
assertions and 40 payment primitive assertions. Admin list testing exposed the
Auth table privilege boundary, addressed by the guarded projection above.

All 879 assertions then passed, including 49 admin assertions. The initial real
HTTP run passed 35 tests with cleanup and runtime log privacy PASS. Encryption
passed 15 tests and payment utilities 27. The final safeguards add a third
forward-only migration and new tests: disabled payment status precedes missing
encryption config; decision text cannot embed the exact reference; audit failure
rolls back payment/entitlement; service audit TRUNCATE is denied. Final acceptance
must rerun everything against the expanded clean rebuild.

Three checkpoints are pushed: 86572ff (primitives), 4ad815a (API) and ac9ce16
(admin decisions). An approval-service usage limit interrupted one container
inspection before execution; it was not an unsafe-action rejection. After the
user requested continuation, normal approved local checks resumed.

The HTTP key remains exclusively in process/pipe memory. Fixture audit rows are
removed only by a local test-superuser transaction with a transaction-local
replication setting; ordinary service mutation and table-owner UPDATE/DELETE
immutability are tested. No production trigger is disabled or rewritten.

## Final Acceptance

Clean reset applied all nineteen migrations and the unchanged seed, exit 0.
All 892 database assertions passed (788 preserved, 104 new). Full warning lint
has only the known unused method parameter in the original payment hash helper.
Payment unit/encryption tests passed 28/16, and all 148 preserved unit cases were
rerun: 192 total, no failures/skips. HTTP passed 38 payment, 18 feedback, 31 OCR,
31 progress and 20 original API tests: 138 total, no failures/skips. Runtime
privacy and exact progress clock restoration passed. No provider was contacted
except synthetic local mocks for the preserved Vision/Gemini regression suites.

Final inspection found no Auth users/profiles/admins, offers/submissions,
entitlements/audits, sessions/responses, reports/items, jobs, paper uploads or
Storage objects. Payments, beta, feedback and OCR are false. No hosted project
is linked. Only the temporary test runtime is stopped after verification; core
local services remain available. Provider safety ledgers may retain synthetic
dispatch counters by design, not candidate records or queued jobs.

Two runtime transitions produced failed development runs: early gateway/auth
and dependency failures in progress (26/31 pass), then one feedback setup 500.
Cleanup still succeeded. Sources were frozen; safe diagnostics found no OOM,
restart or boot-error evidence, and repeated public/auth probes subsequently
passed. The exact startup cause is unproven. Fresh/settled isolated runs passed
all suites without automatic assertion retries. This local harness startup
intermittency remains documented; no application/test assertion was weakened.

The final validation review aligns limits with normalized text, removing an
unnecessary raw-text cap. Leading/trailing whitespace is trimmed before embedded
control validation. Unicode line/paragraph separators are rejected. Extra tests
cover long surrounding whitespace and the separator case. The final payment
HTTP run confirms normalized duplicate detection on whitespace and NFC inputs.

No API contract change, frontend integration, payment-provider API/webhook,
screenshots/chat storage, admin UI, new subscription, privacy worker, package
installation, runtime download, Docker/WSL change or hosted deployment occurred.
The seven unrelated deletions and an unrelated B2B planning document remain
untouched and excluded from Phase 6 commits. The planning document was committed
separately as 7140922 during this work; its commit is preserved. Key rotation and arbitrary-prose privacy
classification remain the documented operational limitations, not new features.

The extra post-HTTP DB command first timed out at host connection, before running
assertions. Direct readiness was healthy. With the temporary runtime stopped,
the same required command passed all 892 assertions again (20 seconds). The final
core local services are healthy, while the temporary runtime remains stopped.
