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
  60/minute, using existing private counters. Valid business failures count;
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
- Existing audit request_id is UUID while API request IDs may have req_ prefix.
  UUID request IDs are retained; other valid request IDs map deterministically
  to a domain-separated SHA-256 UUID for correlation, without schema changes.
- Feature disable blocks offers/new submission, but owned history and admin
  review/decisions remain available for payments already submitted.
- No new public endpoint, provider call, frontend, dependency or deployment.

## Verification

Implementation and verification in progress. Exact results will be recorded
after the clean-reset, new suites and complete regression matrix finish.

The first database run caught unauthorized grants on private API validation
helpers and a missing timestamp helper permission in candidate history. The new
history function now follows the established self-contained invoker pattern;
all existing helper grants remain unchanged. The second run passed all 788 prior
assertions and 40 payment primitive assertions. Admin list testing exposed the
Auth table privilege boundary, addressed by the guarded projection above.
