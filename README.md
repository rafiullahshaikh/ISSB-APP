# Qiyadat — ISSB WAT Practice

Qiyadat is an independent Word Association Test practice prototype. The four
HTML pages currently run in the browser with vanilla HTML, CSS, JavaScript, and
local storage. Phase 1 adds the Supabase database and security foundation. Phase 2 adds an
authenticated Edge Function API; frontend integration remains deferred. See
`backend/VERIFICATION.md` for verified results and outstanding runtime blockers.

`API_SPEC.md` is the binding API contract. It takes precedence over other
documentation and implementation choices. The backend is Supabase-first:
Supabase Auth, PostgreSQL with RLS, private Storage, and a Supabase Edge Function router.

## Project structure

```text
API_SPEC.md                 # Binding API contract
index.html                  # Landing page
wat-practice.html           # Existing practice flow, unchanged
wat-results.html            # Latest-session results, unchanged
wat-dashboard.html          # Local history and progress, unchanged
supabase/
  config.toml               # Local project configuration only
  migrations/               # Versioned schema, integrity, RLS and Storage changes
  seed.sql                  # Immutable diagnostic-v1 and safe defaults
  tests/database/           # Transactional pgTAP security and constraint tests
  functions/api/            # Authenticated API router and Deno entry point
  functions/_shared/        # Auth, validation, envelopes, cursors and safe clients
  functions/tests/          # Unit and real local HTTP integration tests
backend/
  README.md                 # Local setup, security model and deferred work
  VERIFICATION.md           # Verification results and blockers
  .env.example              # Names only; empty values
  scripts/                  # Offline repository and frontend checks
```

## Existing browser flow

Open `index.html`, then follow practice, results, and dashboard. Serve this
directory through a local web server for consistent shared local storage.
No frontend packages or build step are required.

Browser data remains under `issb_wat_latest_session` and
`issb_wat_session_history`. Authenticated persistence and imports will be added
in a later phase. The existing frontend supports options beyond the backend
v1 contract; backend v1 supports exactly 20 words. This phase does not change
the HTML behavior or silently relax that contract.

## Backend foundation

See [backend setup](backend/README.md) for local Supabase reset, seeding, and
test commands, and [verification status](backend/VERIFICATION.md) for current
results. A clean local reset and all 406 database/security tests passed on
2026-10-05. No hosted project is linked or deployed.

## Disclaimer

Qiyadat is not affiliated with ISSB, the Pakistan Armed Forces, or a government
organization. Practice feedback is not an official assessment, psychological
diagnosis, or selection prediction.