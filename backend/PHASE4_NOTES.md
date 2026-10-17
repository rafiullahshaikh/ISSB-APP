# Phase 4 decisions and investigation - 2026-10-17

Phase 4 is **complete locally**; see VERIFICATION.md for the final clean reset,
694 database assertions, 121 unit tests and 69 HTTP tests. The brief required
resolving upload authorization expiry before implementing uploads, and stopping
before changing the binding contract if the supported mechanism could not meet it.
At the initial investigation checkpoint no migration, API route, provider
adapter, worker, Storage policy, feature flag, frontend file or hosted
configuration had been changed. The historical findings below led to the user's
explicit relay approval; they are not an unresolved blocker. Implementation,
security and worker operation are documented in the paper worker README.

## Observed incompatibility

API_SPEC.md sections 1.3, 3 and 6.1 require direct signed Supabase Storage
uploads, HTTP PUT, upload-only permission and a 900-second URL lifetime.

The standard createSignedUploadUrl endpoint has no per-request expiry input.
Supabase documents a two-hour lifetime. A locally issued token independently
confirmed `exp - iat = 7200`, using the installed storage-api v1.79.28.
Returning an `expires_at` fifteen minutes ahead would not shorten that token.

The signed-upload PUT handler performs the upload as a superuser, bypassing
RLS. Checking an authorization row only in an INSERT policy therefore does not
revoke a previously issued transport token. The local probe issued a token as
the owner, changed the corresponding authorization to `delete_pending`, and
successfully uploaded with that token. The existing private read denial remained
effective. This is an inactive-row test, not a claim that a real fifteen-minute
wait was performed. Source inspection confirms the same bypass applies to an
RLS expiry predicate.

## Alternatives investigated

Supabase's supported S3 interface accepts SigV4 query signatures with explicit
expiry. It must not be dismissed as universally incapable of a 900-second URL.
However, the tested user-scoped option is not an acceptable drop-in here:

- S3 PUT uses `isUpsert: true`. The existing insert-only/no-read/no-update
  policies rejected a correctly authenticated owner PUT with HTTP 403 and an
  RLS denial. The probe does not broaden those policies.
- A user-scoped presigned URL includes the full user access JWT as its session
  token. Extracting that JWT grants the user's wider API permissions, so this
  is not an upload-only capability and must not be returned by this API.
- Server-key S3 signing avoids embedding a user JWT and can limit a signature
  to PUT plus an exact object and expiry. But those credentials bypass RLS; an
  additional reviewed design is needed for active-row enforcement, revocation
  and re-upload after confirmation. This alternative is not implemented or
  claimed verified. No hosted S3 credential was created.

Self-hosted Storage exposes a server-wide signed-upload expiry setting. Changing
local container configuration would need approval and would not establish that
the same setting is available in the intended hosted environment. No such
configuration change was made.

## Approved decision

The user explicitly approved the protected upload relay on 2026-10-17.
API_SPEC.md v1.1.1 records this authorized contract revision before feature
implementation. All nine existing migrations remain unchanged.

The explicit API_SPEC.md revision permits a protected backend upload
relay instead of requiring a direct signed Storage URL. A narrowly scoped,
upload-only capability binds user/session/upload and the exact server expiry;
the immutable row binds size/type/checksum. The relay rejects inactive/expired
rows and validates bytes before the isolated server client writes to the
private bucket. It grants no list/read permissions. The preparation response
keeps its documented shape and PUT method, with the explicitly revised relay
URL. Its exact route, capability and replay behavior were documented in the
binding specification before implementation.

OCR remains disabled in normal seed defaults. Do not
silently substitute a two-hour transport token plus a fifteen-minute OCR check;
that would not satisfy the specified URL validity and insertion rules.

## Reproduction and results

```powershell
node --experimental-strip-types backend/scripts/probe_upload_expiry.ts
```

The script uses only the already installed CLI, local services and disposable
synthetic accounts. It refuses a nonlocal API URL. Keys, JWTs, signed URLs,
provider responses and object paths are not printed. No packages are required.
It removes its object through the Storage API before deleting its Auth fixtures.
It is a characterization script, not a production signer or OCR test suite.

Final characterization run: exit 0, all four reported checks passed:

1. Preserved insert-only RLS denies user-scoped S3 PUT.
2. A standard issued upload token has a 7200-second lifetime.
3. Standard signed PUT accepts bytes after its authorization becomes inactive.
4. Private object reading remains denied.

Earlier probes failed during local Auth warm-up (HTTP 504/timeout), then owner
S3 PUT failed with HTTP 403. These failures were investigated, not counted as
successful upload authorization. The final probe expects and identifies the
RLS denial. Final database inspection found zero investigation accounts, zero
paper upload rows and zero paper Storage objects. OCR, feedback, payments and
beta flags were all false.

The following preservation results describe the initial investigation checkpoint.
No Vision or Gemini request was made. Preservation reruns passed 580 database
assertions, 62 existing unit/worker tests and both offline repository/frontend
checks. Application-only lint has just the known Phase 1 warning. Default lint
also reports stock pgTAP extension diagnostics; see VERIFICATION.md. Clean reset
and HTTP suites were not rerun. The previous Phase 3 verification remains
historical evidence, not a fresh claim that all suites passed in this phase.

## Implementation decisions

- Verified relay/Storage failures before OCR must not strand the canonical demo.
  A service-only failure record transitions an unconfirmed paper session to its
  trusted technical-failure state. Preparation then removes old objects before
  issuing fresh authorizations on the same session. It does not reset words,
  timestamps or lifetime access. Active transfers must settle before retake.

- Preparation page-count/ordering failures use VALIDATION_ERROR with safe field
  details, as Section 6.1 requires. PAPER_UPLOAD_INCOMPLETE is reserved for the
  OCR/upload-file completeness checks documented by Section 6.2 and the relay.
  A final additive migration aligns these codes without rewriting a verified
  migration or changing request/response JSON.

- New authorizations use only protected relay URLs, never Storage transport
  tokens. A new restrictive policy blocks direct candidate writes to new paths;
  original legacy-path policies and all nine verified migrations are unchanged.
- Existing SECURITY DEFINER session guard behavior is retained, with narrow
  trusted same-session OCR rerun/recovery edges. A failed unconfirmed OCR session
  can prepare replacement images only after deletion of the previous images;
  this implements Section 12.1 recovery without another lifetime demo.
- Logical page reservations are distinct from the persistent physical dispatch
  safety ledger. Retries do not double-consume the same usage reservation, but
  every actual attempt counts toward the absolute 900-page monthly safety cap.
  Lost dispatch acknowledgements are fenced by job attempt and do not recount.
- Never-dispatched failures release reserved quota. A dispatched request with
  unknown outcome is conservatively retained; OAuth preflight happens before
  dispatch. No report quota is used by OCR.
- Raw Vision payload/hierarchy is never persisted. Partial-job page checkpoints
  retain only bounded text/confidence until completion/expiry. Success retains
  only 20 review entries; confirmation removes all transient OCR text.
- Mapping cannot infer an omitted unnumbered position reliably. Such sequential
  mapping is explicitly flagged for review; numbered gaps never shift. Extra or
  ambiguous lines are retained or fail the bounded draft, never truncated.
- Normal seed flags remain disabled. The local polling runner is supplied, not
  a hosted scheduler. Physical purging depends on trusted cleanup invocation;
  API expiry is independently enforced. Vendor request logs require a separate
  hosted infrastructure access/redaction/retention review, not application
  logging of image paths or tokens.

## Primary sources

- Standard upload lifetime and API parameters:
  https://supabase.com/docs/reference/javascript/storage-from-createsigneduploadurl
- Installed version's signed-upload handler (superuser upload):
  https://github.com/supabase/storage/blob/v1.79.28/src/http/routes/object/uploadSignedObject.ts
- Installed version's URL issuance (configured expiry, no body TTL):
  https://github.com/supabase/storage/blob/v1.79.28/src/http/routes/object/getSignedUploadURL.ts
- Supported S3 authentication, RLS and server-key distinctions:
  https://supabase.com/docs/guides/storage/s3/authentication
- S3 query presigning compatibility:
  https://supabase.com/docs/guides/storage/s3/compatibility
- Installed version's S3 PUT implementation (`isUpsert: true`):
  https://github.com/supabase/storage/blob/v1.79.28/src/storage/protocols/s3/s3-handler.ts
- Installed version's S3 signature expiry and session token verification:
  https://github.com/supabase/storage/blob/v1.79.28/src/storage/protocols/s3/signature-v4.ts
- Self-hosted configuration source:
  https://github.com/supabase/storage/blob/v1.79.28/src/config.ts
- Vision handwriting requests and response hierarchy:
  https://docs.cloud.google.com/vision/docs/handwriting
- Vision REST endpoint and authorization scopes:
  https://docs.cloud.google.com/vision/docs/reference/rest/v1/images/annotate
- Service-account JWT/OAuth exchange:
  https://developers.google.com/identity/protocols/oauth2/service-account
