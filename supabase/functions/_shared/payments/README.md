# Manual payment modules

`reference.ts` owns NFC/trim validation, masks, SHA-256 and authenticated
encryption. Envelope bytea is version byte 1, 12-byte random nonce, then AES-GCM
ciphertext plus 16-byte tag. Associated UTF-8 data is the versioned domain,
provider and reference hash. The secret must decode canonically to 32 bytes.
Any missing key, unknown version, changed associated data, tampering or invalid
plaintext fails with INTERNAL_ERROR and no diagnostics. No dependency is added.

`api.ts` owns exact request/query validation, signed pagination and response
projection. Admin list returns only the requested page and decrypts that page,
after allowlist authorization. Exact search hashes normalized input; the SQL
query matches provider/hash without table-wide decryption. Ciphertext, hashes,
notes and internal fields never enter candidate responses. All private responses
use no-store; public offers have max-age=30 and a content-derived ETag.

JWT verification uses existing Auth calls, never metadata. User-scoped history
uses auth.uid()/RLS; isolated service calls accept the verified actor only.
Database mutation functions are invoker/service-only, with an empty search_path.
The admin list alone requires a definer context to join Auth email, guarded by
service-role assertion and active admin membership before the fixed query.

Payment submit reserves the existing canonical idempotency key in the same
transaction as its snapshot insert and response. Random ciphertext is excluded
from the canonical request hash. Only offer, method and normalized reference
hash enter it. Same-key replays return exactly the original 201 body, bypassing
rate hits. Expected business failures roll back the insert/key but keep the rate
hit. Global provider/reference uniqueness and one pending/user stay authoritative.

Decisions lock actor/candidate profiles in UUID order, membership and payment,
then paid entitlement rows. Repeated/competing decisions fail. Approval extends
the latest active paid expiry, preserving queued renewals; initial access starts
at server decision time. Expiry is captured access_days later. Audit insertion
and entitlement/payment changes all roll back together. Beta and quotas retain
their existing rules. Audit rows have no free-text field; service update/delete/
truncate is denied. API req_ IDs map to domain-separated UUID audit correlation.

Exact submitted references cannot appear anywhere in notes or rejection text:
a bounded database substring/hash check avoids decrypting them. Notes/messages
are 1-500 NFC code points, single-line plain text, and reject markup, common
credential, contact and transcript patterns. Validation cannot classify every
kind of private prose; reviewed operator procedures are still required.

Environment: PAYMENT_TRANSACTION_ENCRYPTION_KEY, empty in both examples.
Supply outside the repository. Do not overwrite a key while encrypted records
remain; versioned rotation/keyring support is deferred. Normal development flags
remain disabled, with no seeded admin, offer, price or recipient account.

Tests: npm.cmd run test:payments:unit, test:payments:crypto, test:payments:http.
The Windows HTTP harness uses a named pipe for the synthetic key, cached local
Edge Runtime and disposable Auth users. It checks runtime logs in memory and
restores fixtures/flags in finally. Local superuser-only audit cleanup uses a
transaction-local setting; application grants/policies/triggers are unchanged.
All HTTP suites must run serially with function sources frozen. No provider or
hosted Supabase project is contacted. See backend/README.md and PHASE6_NOTES.md.
