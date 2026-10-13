# Qiyadat Supabase foundation

The root `API_SPEC.md` is the binding API contract. Follow it whenever other
documentation or code differs. This backend uses Supabase Auth, PostgreSQL,
Row Level Security, private Storage, and future Edge Functions. Phase 1
implements the database and security foundation only.

## Local prerequisites and setup

Use the already-installed Supabase CLI 2.119.0 through `npx` and a running Docker
Desktop Linux container engine. Do not install tools, link a hosted project,
or deploy as part of this phase. Python 3.11+ and Node.js are used only for the
offline repository checks, not for a backend server.

Run these commands from the repository root after local prerequisites exist:

```powershell
npx --offline --no-install supabase --version
docker version
npx --offline --no-install supabase start -x studio,imgproxy,mailpit,edge-runtime,logflare,vector,realtime,supavisor
npx --offline --no-install supabase db reset --local
npx --offline --no-install supabase test db
npx --offline --no-install supabase db lint --local --level warning
python backend/scripts/verify_repository.py
node backend/scripts/verify_frontend.cjs
git status --short --untracked-files=all
```

On this machine the installed CLI can also be run directly from an
interactive PowerShell terminal. This was the verified workaround when
noninteractive `npx` resets failed with Windows `uv_spawn`/container errors;
no package download is involved:

```powershell
$qiyadatCli = Join-Path $env:USERPROFILE 'node_modules\supabase\dist\supabase.js'
node $qiyadatCli db reset --local
node $qiyadatCli test db
node $qiyadatCli db lint --local --level warning
```

The path describes this machine's existing installation, not a required
repository dependency location. In automated verification, use a terminal/PTY
context for these commands. A successful reset and tests are still required;
failed process launches do not validate the schema.

`npx --offline --no-install supabase db reset --local` recreates the local database, applies all migrations
in filename order, and runs `supabase/seed.sql`. It destroys local database
data; use only synthetic local development data. A fresh reset is the required
verification baseline. No hosted connection, project reference, or remote
credentials are needed. Do not use `--linked`, `--db-url`, `link`, `db push`,
or deployment commands for Phase 1.

Tests live under `supabase/tests/database`; `supabase test db` discovers the
SQL suite. The suite uses pgTAP, inserts only synthetic `.invalid` accounts,
and rolls back all fixtures and temporary policies. Run reset before testing
so seed assertions have a clean baseline. `db lint` is supplementary; both
reset and tests must pass. Inspect reset output for warnings, and investigate
any migration or lint warnings before marking the phase complete.

Local API, database, Studio, and test mailbox use ports 55321, 55322, 55323,
and 55324 respectively; the shadow database uses 55320. These replace the
usual 5432x ports because Windows reserves 54283–54382 on this machine.
The local base URL here is `http://127.0.0.1:55321`; the API path and contract
remain unchanged. Other machines may use different unreserved ports.
The config uses `[local_smtp]`, replacing the deprecated `[inbucket]` section.
Email OTPs remain in the local mailbox when that service is enabled. The
low-memory start command above excludes the mailbox and Studio. No Auth or
frontend integration is included yet. The future Supabase Auth email template
must display `{{ .Token }}` for code entry rather than require a magic link.

For a genuinely empty local stack, stop the local project with the CLI's
`supabase stop --no-backup`, start it again, and rerun reset and tests. This
removes this local project's runtime state, so preserve needed local work first.
The repository config is already initialized; do not overwrite it with `init`.

On this 8 GB Windows machine, the user's working WSL2 settings are `memory=4GB`,
`processors=2`, and `swap=4GB` in `%USERPROFILE%\\.wslconfig`. The reduced-service
start command above avoids the previous database health-check failure. Docker
Desktop must remain running, and every Supabase command must run from this
repository root so the CLI reads the configured ports. No WSL or Docker
installation or memory-setting change is performed by the repository scripts.

## Migration order

| Migration | Responsibility |
|---|---|
| `20261002000100_database_foundation.sql` | Enums, all 22 contract tables, constraints, ownership FKs, uniqueness and indexes |
| `20261002000200_integrity_and_auth.sql` | Auth-linked candidate profiles, timezone validation, immutable published sets, transition and snapshot guards, timestamps, upload limits, deletion access revocation |
| `20261002000300_rls_and_storage.sql` | RLS on every application table, explicit grants, owner policies, restricted columns, private upload bucket and restrictive Storage guards |

Schema changes must be new versioned migrations. Do not edit an already applied
migration in a shared environment. These three files are the initial
foundation, already applied locally in the user's October 3/4 verification.
The assistant independently confirmed a clean reset and all 406 passing
pgTAP tests on October 5. `VERIFICATION.md` records the commands, warning
review, resolved runtime failures and verification limits.

## Seed data and constants

`diagnostic-v1`, version 1, uses the first 20 entries of the current HTML
`WORD_BANK`, in original order: Courage through Success. The HTML currently
contains 100 words and shuffles practice sets; it does not define a persistent
20-word version. Using its first 20 establishes the requested immutable seed
without changing the browser flow. A published set requires all 20 unique
positions and normalized words; later edits require a new draft version.

Set and session rules enforce exactly 20 words, 15 seconds per word, 2,000 ms
transport grace, and a 280-code-point normalized answer limit. Seeded settings
mirror all constants in section 3 of the API spec, including the 900-page OCR
cap, three-report rolling 24-hour limit, and one lifetime diagnostic allowance.
OCR, feedback, payments, and beta flags start `false`. Their eventual API
responses reflect server configuration, not the illustrative spec examples.
No Auth account, admin membership, or payment offer is seeded.

## Security boundary

All 22 application tables have enabled and forced RLS. Anonymous clients have
no application-table privileges. Authenticated candidates can read only their
own candidate-facing records, and only while their account remains enabled.
No application table allows client inserts or deletes. Candidate UPDATE is
limited by column grants to `profiles.display_name` and `profiles.timezone`,
with owner RLS and database validation. Consent writes go through the future
server endpoint; browser clients can read consent history, but cannot forge,
overwrite, or delete it. Server cleanup can delete consent rows on erasure.

Auth account creation always creates a candidate profile. No metadata is
copied into authorization fields. `profiles.role` is a candidate default;
the future API derives admin role from active `admin_users` membership.
The admin allowlist is service-managed and inaccessible to browser clients.
An actual allowlisted admin using the normal browser JWT still cannot read
other candidates or decide payments directly through PostgREST.

Admin endpoints in a later phase must validate the user's JWT, then check
the protected allowlist through an isolated service context. The private
`is_active_admin` helper is executable only by `service_role`; it is not a
public RPC. Never use editable metadata, a role submitted by the client, or
email as an authorization source. Service clients must never share user
Authorization headers. Service-role bypass is intentional and grants trusted
server access; it is not an alternative browser credential.

Protected payment ciphertext/hash/notes, internal job locks, paper object
paths, export paths, and deleted-image metadata have no candidate read grants.
Settings, audit rows, counters, idempotency records, offers, and word-bank
tables have no browser grants. The future public API exposes only the approved
configuration and offers. Audit rows have no free-form data field and cannot
be updated, deleted, or truncated by the service role; an immutable trigger
also guards owner UPDATE/DELETE.

Creating a deletion request disables account access immediately in the
database, including for an old JWT. The future endpoint still must require
recent Auth, disable the Auth identity, queue cleanup, and delete Auth last.
Payment ownership can be nulled on erasure; decision actors and audit subject
UUIDs survive without retaining profile content. Payment decision actors are
validated against the active allowlist when the decision is written, and a
final decision cannot be edited. Their retained UUIDs have no identity FK that
would prevent erasing an admin's Auth/profile identity.

## Storage

The `paper-uploads` bucket is private, accepts only JPEG/PNG/WebP, and limits
each object to 8 MiB. Application metadata enforces up to four pages and 24 MiB
per session. Authorized names are exactly:

```text
<user_id>/<session_id>/<upload_id>.<jpg|png|webp>
```

The browser cannot create metadata authorizations. Only a trusted server can
prepare them for a finished paper session in `awaiting_upload`. Authenticated
INSERT requires an exact own unexpired prepared metadata path and an enabled
account. Owning a prefix is insufficient. Restrictive policies deny paper
reads/listings, updates/upserts, and deletes, including if unrelated permissive
Storage policies are added. Candidates receive upload permission only.

The metadata authorization expires within 900 seconds. No signed-URL endpoint
exists in Phase 1. Supabase's documented `createSignedUploadUrl` grants a
two-hour upload token; it must not be substituted for the API contract's
900-second URL. The later upload phase must choose and test a mechanism that
enforces that exact lifetime and ownership at the Storage HTTP boundary.
No API-contract deviation is made in this phase. See the
[Supabase signed-upload reference](https://supabase.com/docs/reference/javascript/storage-from-createsigneduploadurl).

Bucket MIME settings are not magic-byte validation. Future code must validate
actual type, size, checksum, contiguous page order and expected path before
OCR, and immediately delete confirmed images or queue cleanup. The 24-hour
metadata expiry indexes support cleanup; indexes do not schedule deletion.

## Payment reference handling

Only a protected encrypted reference, normalized SHA-256 hash, and masked
display value are persisted. Candidate clients cannot access ciphertext or
hashes. The service-only normalization/hash helper applies Unicode NFC and
surrounding-whitespace removal, rejects blank/overlong references, and
preserves case and separators. The spec does not enumerate provider-approved
separators, so none are guessed; the later payment adapter must establish those
rules before submission is enabled. The provider/hash unique constraint is
global and continues reserving rejected references. One pending submission
per user is enforced by a partial unique index.

The future isolated server must encrypt references using a secret-managed
key, generate the hash/mask from the same normalized reference, snapshot a
currently valid offer, and perform approval, entitlement creation, and audit
in one transaction. Synthetic test ciphertext is not a production encryption
implementation. No payment offer or approval endpoint exists in Phase 1.

## Verification scope and intentionally deferred work

The SQL suite checks anonymous denial, both directions of cross-user reads,
safe versus forbidden profile writes, self-promotion and entitlement denial,
protected columns, allowlisted browser-admin restrictions, trusted service
access, published version immutability, duplicate constraints, invalid states,
positions, scores, timestamps, enums, and private Storage policies. It also
tests broad temporary Storage policies against restrictive bucket guards.

The offline scripts check table/contract coverage, seed constants, config,
credential patterns, HTML hashes, JavaScript syntax and local navigation links.
They cannot compile SQL, prove RLS, validate signed URLs, or prove browser
runtime behavior. Git tracking must be checked separately in a real checkout.
Current results and precise blockers are in `VERIFICATION.md`.

Supabase Storage now prevents direct SQL deletion of objects by default. The
SQL test transaction enables `storage.allow_delete_query` solely to exercise
the RLS policies beneath that guard; the transaction rolls back. Never set
this flag in migrations or application functions. Real cleanup must use the
Storage API so both database metadata and object bytes are deleted correctly.

Lint reports one intentionally retained warning: the `method` parameter in
`private.payment_transaction_hash` is reserved for provider-specific separator
rules. The hash covers the normalized reference, while the unique constraint
includes both `payment_method` and `transaction_id_hash`. No separators are
guessed, and the unused parameter does not create a cross-provider collision.

Later phases intentionally own all HTTP endpoints and JSON schemas, strict
simulation acceptance RPCs, finish/import/idempotent replay, consent acceptance,
transactional rolling/global quota enforcement, job claiming with `SKIP LOCKED`,
bounded retry/backoff and schedules, OCR and candidate confirmation, deterministic
session score aggregation, validated Gemini feedback, payment approval/rejection
transactions, exports/deletion workers, signed URL lifetimes, rate limiting,
provider/image validation, frontend integration and hosted deployment. The
present tables and grants support those workflows but do not implement them.

The spec mentions abandoning sessions, expiry and OCR re-runs without defining
additional abandonment/expiry states or all recovery transitions. Phase 1 uses
only the states and transitions in section 12. Later RPC work must report and
resolve that ambiguity before adding any public state or transition.

## Credentials and environment

`backend/.env.example` contains variable names with blank values. No secret is
needed for migrations or seeds. Keep all real `.env` files ignored. Server
credentials, encryption keys, Google credentials, Gemini keys and scheduler
secrets belong in Edge Function secrets/Vault in a future deployment. Only
publishable browser credentials may reach frontend code. Never commit Auth
exports, local uploads, signed URLs, generated local database state, or real
candidate answers/payment records.

Useful official references:
[CLI configuration](https://supabase.com/docs/guides/local-development/cli/config),
[database seeding](https://supabase.com/docs/guides/local-development/seeding-your-database),
[CLI test commands](https://supabase.com/docs/reference/cli).
