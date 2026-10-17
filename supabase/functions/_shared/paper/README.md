# Private paper pipeline

The binding contract is API_SPEC.md v1.1.1. The user explicitly approved its
protected upload relay on 2026-10-17 after a local probe demonstrated that
standard Supabase signed-upload tokens last two hours and bypass insertion RLS.
No standard Storage signed-upload token is returned by this implementation.

## Routes and authorization

The API router exposes authenticated owner-only preparation, binary PUT relay,
OCR enqueue/draft and confirmation routes. All use the shared request IDs,
errors, CORS and private/no-store conventions. Other owners receive NOT_FOUND.
The binary route additionally requires the HMAC upload capability returned by
preparation. The capability binds owner, session, upload and the exact database
expiry, contains no user JWT, and grants no standalone account/Storage access.
The bearer/apikey headers are still required. Tokens/URLs are never logged.

The fixed private bucket is paper-uploads. New paths are exclusively
`paper-pages/<user-id>/<session-id>/<upload-id>.<jpg|png|webp>`. A restrictive
Storage policy prevents candidates from bypassing the relay on these new paths,
even if they infer a path. Existing legacy-path policies remain unchanged.
Candidates have no list/read/update/delete permission. Server Storage clients
never receive caller headers and remove only a validated exact key.

Preparation accepts 1-4 contiguous ordered pages, 8 MiB per image, 24 MiB total,
the documented MIME types and lowercase SHA-256. Repeating identical preparation
reuses the original rows and expiry; it cannot add pages or extend permission.
The relay checks capability, state and expiry before and after body reception,
validates actual bytes, claims a fenced upload lease, writes without upsert and
commits the uploaded marker. A write crossing expiry fails and is cleaned up.
An accepted identical replay returns 204 only while authorization and session
remain active. There is no upload after OCR starts or after confirmation.

Image checks include exact fixed path, byte count, calculated SHA-256, magic
bytes, bounded JPEG/PNG/WebP container structure, PNG CRCs, terminal markers and
no trailing polyglot data. Text/EXIF/XMP/animation container chunks are rejected;
unsupported or malformed encodings fail closed. No browser filename, MIME,
dimension or checksum is trusted as evidence. No image is made public.

## Workers and local invocation

Serve all configured functions using the installed CLI and an untracked private
environment file:

```powershell
$cli = Join-Path $env:USERPROFILE 'node_modules\supabase\dist\supabase.js'
node $cli functions serve --no-verify-jwt --env-file <untracked-env-path>
npm run worker:paper
```

The local API base is http://127.0.0.1:55321/functions/v1/api/v1.
The two internal worker URLs end in `/functions/v1/ocr-worker` and
`/functions/v1/paper-cleanup`. They accept POST `{}` with the private
QIYADAT_WORKER_SECRET bearer, at least 32 characters. Candidate/publishable
tokens and caller-selected jobs/users/clocks are rejected. The local polling
runner uses only these fixed loopback URLs and the worker secret. It polls
both every five seconds, stops with Ctrl+C and needs no Google credential in
its own environment. Production must schedule both protected workers; no
hosted scheduler, project link, secret or deployment is created in Phase 4.

OCR stays disabled in seed defaults. Preparation/enqueue and processing fail
with FEATURE_DISABLED while disabled; cleanup remains available for privacy.

## Server environment

- Automatically injected Supabase URL/publishable/service keys, as before.
- QIYADAT_WORKER_SECRET: shared internal worker bearer.
- QIYADAT_PUBLIC_API_URL: optional trusted external API base ending in
  `/functions/v1/api/v1`; needed when the internal Supabase origin differs.
- OCR_PROVIDER: google_cloud_vision.
- GOOGLE_CLOUD_PROJECT_ID: server billing/API project.
- GOOGLE_CLOUD_VISION_CREDENTIALS_JSON: service-account JSON; never a frontend
  value or tracked file. Its project must match the configured project.
- GOOGLE_CLOUD_VISION_TIMEOUT_MS: defaults to 20000, maximum 30000.
- GOOGLE_CLOUD_VISION_ENDPOINT: defaults to https://vision.googleapis.com.

The adapter signs an RS256 service-account JWT using Web Crypto and exchanges
it at Google's fixed OAuth token endpoint. The token has the cloud-vision scope
and is cached in memory only, with expiry skew. Vision receives image bytes in
DOCUMENT_TEXT_DETECTION requests with English hints, not public image URLs.
Gemini is never used for OCR. No npm or provider SDK dependency is required.

Automated HTTP tests use synthetic local credentials and a local HTTP Vision
mock. The local override requires QIYADAT_LOCAL_TESTS=true, a local Supabase
hostname and a loopback/host.docker.internal target; it cannot redirect hosted
processing to an arbitrary endpoint. Real service credentials are unnecessary.

## Durable jobs and quota

Enqueue validates all privately downloaded images before an atomic transaction
creates the OCR job, reserves one ocr_page usage unit per upload/provider
operation and transitions the session. The idempotency key scopes owner and
route; exact replay works even after image deletion, changed input conflicts,
and concurrent requests create one job. OCR never consumes report allowance.

Claims use a fresh worker UUID, profile/session/job lock order and five-minute
leases. Every page dispatch/completion checks that fence and expiry again.
Provider calls occur outside transactions. At most three attempts are allowed,
with 5- then 10-second backoff. Stale leases are recovered; old workers cannot
write into a later attempt. Completed page checkpoints avoid resubmitting those
pages when a later page fails. Only text/confidence lines needed for mapping are
temporarily stored, never a complete provider response or document hierarchy.

Logical usage is reserved once per job/upload and consumed once on an accepted
HTTP provider response. Replaying an acknowledgement does not recount it.
Never-dispatched terminal failures release those units. Dispatched requests
with an unknown outcome remain conservatively reserved instead of refunding a
potentially billed request. A separate persistent UTC-month dispatch ledger
also caps **actual attempts, including retries**, at 900. Queue admission includes
reserved undelivered pages. This prevents retries or account cleanup from
bypassing the physical provider-call safety cap, without consuming a second
logical reservation for a retry. OAuth failure occurs before page dispatch.

Explicit OCR reruns use a new job/request and count new page operations; each
successful rerun increments ocr_revision. A verified terminal OCR failure may
retry on the same canonical demo. Preparing replacement photos first deletes
the old images and only then restores awaiting_upload on that same session;
it never resets the lifetime claim, word snapshot or original timestamps.
Recovery is limited to the original unconfirmed upload lifetime and trusted
server failure state, not ordinary abandonment or a client failure flag.
The same recovery also covers verified relay write failures and a missing or
corrupt private object discovered before OCR. An interrupted upload cannot
strand the free demo: cleanup precedes new authorization, active transfers must
settle, and no report/page quota is consumed before a valid OCR job is queued.

## Mapping, confirmation and reports

Mapping prefers explicit 1., 1), 1 - and 01. numbering. Numbered gaps remain
blank; later numbered answers never shift. Duplicate/invalid/extra lines are
retained in a review-flagged entry rather than silently discarded. Only an
explicitly indented continuation is merged as an unambiguous wrapped line.
Without numbering, nonempty lines map sequentially and all require review,
because an omitted position cannot be inferred reliably. Missing and
low/unknown-confidence entries require review. More text than can fit the
bounded draft fails OCR instead of truncating it. Words are always read from
the immutable session snapshot, not copied from the provider.

Successful OCR creates exactly 20 draft rows and awaiting_confirmation, never
canonical answers. Confirmation locks the current revision, validates each
position exactly once and NFC-normalizes at most 280 Unicode code points.
Blank text is allowed and capitalization/wording otherwise preserved. The
transaction creates locked ocr_confirmed answers, marks confirmation, returns
the session to finished, deletes transient OCR text and marks images pending
immediate deletion. Stale revisions cannot overwrite a newer draft.

Deletion occurs after commit; temporary Storage failure still returns successful
confirmation with delete_pending. Only successful object removal/absence permits
metadata to become deleted. Cleanup retries pending deletion, expired prepared
authorizations, 24-hour abandoned images, expired drafts/cache and exact orphan
keys under the controlled prefix. It never deletes canonical responses/reports
or recursively removes a bucket/prefix. Metadata expiry is enforced even while
workers are offline; physical purging requires the trusted cleanup runner.

The original Phase 3 report implementation is reused. Its paper eligibility
gate requires server confirmation plus 20 locked ocr_confirmed responses.
Existing consent, entitlement, quotas, scoring, retry and safety rules remain
in effect. Only confirmed word/answer pairs reach Gemini, never image bytes,
unconfirmed OCR, Storage paths or identity. Reports retain ocr_confirmed source.

Application logs use the safe allowlist only. Supabase platform/gateway/Storage
request logs are separate infrastructure: their access controls, redaction and
retention must be reviewed before hosted operation; the application does not
claim to rewrite those vendor logs.

## Tests and optional real smoke

```powershell
npm run test:ocr:unit
npm run test:ocr:worker
npm run test:paper:storage
npm run test:vision:mock
npm run test:paper:cleanup
npm run test:ocr:http
```

The HTTP harness starts existing local components and mock providers, uses real
local Auth/RLS/Storage, exercises both report and OCR workers, verifies sensitive
runtime-log sentinels, restores flags and removes fixture objects/accounts. The
outage tests temporarily stop only the project's Storage container to verify
deletion fallback and upload recovery, and restart it in finally. Run HTTP suites
serially. The precondition
probe in backend/scripts/probe_upload_expiry.ts is historical characterization,
not the production upload implementation or a Phase 4 acceptance suite.

A real-provider smoke test is optional and manual: configure private server
credentials outside tracked files, explicitly enable OCR only locally, prepare
and upload synthetic pages through the authenticated relay, queue OCR, invoke
the worker, review/correct all positions and confirm. Verify deletion and restore
flags afterward. Supply Gemini settings and current consent only to additionally
test reports. Automated tests never contact Google. No real-provider smoke has
been performed. Urdu/PDF, frontend camera UI, payments/admin, progress, privacy
export/deletion workers and hosted scheduling/deployment remain deferred.
