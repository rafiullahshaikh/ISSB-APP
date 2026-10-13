# Qiyadat Backend API Specification

**Version:** 1.1.0  
**API version:** `v1`  
**Status:** Source of truth for the WAT MVP  
**Last updated:** 2026-10-06

This document defines the public contract between the Qiyadat frontend and the
Supabase-first backend. Database migrations, Row Level Security (RLS) policies,
Edge Functions, background jobs, and frontend API calls must follow this
contract.

Qiyadat provides practice guidance only. Nothing returned by this API is an
official ISSB assessment, psychological diagnosis, or selection prediction.

Version 1.1.0 changes free access from one lifetime report on any eligible
diagnostic session to one authenticated, server-tracked, 20-word diagnostic
demo with one report per account. The API remains `v1` because no public v1
endpoint has been deployed; implementations must adopt this policy before the
first public release.

---

## 1. Conventions

### 1.1 Base URL

Production:

```text
https://<project-ref>.supabase.co/functions/v1/api/v1
```

Local development:

```text
http://127.0.0.1:54321/functions/v1/api/v1
```

The first `api` segment is the Supabase Edge Function name. `/v1` is the
application API version. Breaking contract changes require `/v2`.

### 1.2 Authentication

Qiyadat uses Supabase Auth email one-time codes. Account creation, requesting an
OTP, verifying an OTP, refreshing a token, and signing out use the official
Supabase Auth client directly and are not duplicated by this API.

Authenticated API requests include:

```http
Authorization: Bearer <supabase-user-access-token>
apikey: <supabase-publishable-key>
```

Admin endpoints use the same user access token. The API additionally verifies
that `auth.uid()` exists in `admin_users`. A client-supplied role, profile field,
or user metadata value never grants admin access.

Only `GET /health`, `GET /config/wat`, and `GET /payment-offers` are public.

### 1.3 Content types

- Requests and responses use `application/json; charset=utf-8`.
- Photo bytes are uploaded directly to the signed Supabase Storage URL returned
  by the paper-upload preparation endpoint.
- Dates use RFC 3339 UTC strings, for example `2026-10-02T09:30:00Z`.
- IDs are UUID strings unless explicitly documented otherwise.
- JSON properties use `snake_case`.
- Monetary values use integer minor units. `150000` means PKR 1,500.00.
- Positions in WAT sets and reports are one-based (`1` through `20`).

### 1.4 Success envelope

Every JSON success response has a `data` property. List responses may also have
`meta`.

```json
{
  "data": {
    "id": "30e8393d-84e2-47fa-bf83-91d5cb66197a"
  }
}
```

Paginated response:

```json
{
  "data": [],
  "meta": {
    "next_cursor": null,
    "has_more": false
  }
}
```

### 1.5 Error envelope

Every error uses this shape:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "The request could not be validated.",
    "request_id": "req_01k6zv1n8s7f0h5k4m2q",
    "details": {
      "fields": {
        "display_name": "Must be 1 to 80 characters."
      }
    }
  }
}
```

Rules:

- `code` is stable and intended for frontend branching.
- `message` is safe to display but may be localized later.
- `request_id` is returned in the `X-Request-Id` response header as well.
- `details` is optional and must not contain secrets, provider payloads,
  candidate answers, or internal stack traces.
- Provider-specific errors are translated to Qiyadat error codes.

### 1.6 Idempotency

The following operations require an `Idempotency-Key` header:

- `POST /wat/sessions`
- `POST /wat/sessions/import`
- `POST /wat/sessions/{session_id}/finish`
- `POST /wat/sessions/{session_id}/paper/ocr`
- `POST /wat/sessions/{session_id}/report`
- `POST /payments`
- `POST /privacy/export`

The key must be 16-128 printable ASCII characters and unique to the user and
operation. Repeating the same key with the same request returns the original
result. Reusing it with a different body returns `IDEMPOTENCY_CONFLICT`.
Idempotency records are retained for at least 24 hours.

### 1.7 Pagination

List endpoints use opaque cursor pagination:

```text
?limit=20&cursor=<opaque-cursor>
```

- Default limit: `20`
- Maximum limit: `100`
- Clients must not parse or construct cursor values.
- Results use a deterministic `created_at DESC, id DESC` order unless an
  endpoint specifies otherwise.

### 1.8 HTTP status codes

| Status | Meaning |
|---|---|
| `200 OK` | Successful read or idempotent operation |
| `201 Created` | Resource created |
| `202 Accepted` | Asynchronous job queued |
| `204 No Content` | Successful operation with no response body |
| `400 Bad Request` | Malformed request or unsupported parameter combination |
| `401 Unauthorized` | Missing, expired, invalid, or insufficiently recent authentication |
| `403 Forbidden` | Authenticated caller lacks access or entitlement |
| `404 Not Found` | Resource does not exist or is hidden from this caller |
| `409 Conflict` | State, version, duplicate, or idempotency conflict |
| `410 Gone` | Session or temporary resource expired |
| `413 Content Too Large` | Upload or request exceeds a configured limit |
| `415 Unsupported Media Type` | Unsupported file or content type |
| `422 Unprocessable Content` | JSON is valid but field validation failed |
| `429 Too Many Requests` | Per-user rate or report limit reached |
| `500 Internal Server Error` | Unexpected backend failure |
| `502 Bad Gateway` | OCR or AI provider returned an unusable result |
| `503 Service Unavailable` | Feature disabled, global quota exhausted, or dependency unavailable |

### 1.9 Caching and sensitive responses

- Authenticated responses use `Cache-Control: private, no-store`.
- `/health`, `/config/wat`, and `/payment-offers` may use short public caching
  with an `ETag`.
- Export download URLs and Storage upload URLs are short-lived and must never be
  written to analytics logs.
- API logs may include IDs, durations, status values, and safe error codes, but
  never answers, OCR text, report narrative, tokens, or transaction IDs.

---

## 2. Error codes

| Code | HTTP | Meaning |
|---|---:|---|
| `INVALID_JSON` | 400 | Body is not valid JSON. |
| `INVALID_REQUEST` | 400 | Request shape or parameter combination is unsupported. |
| `VALIDATION_ERROR` | 422 | One or more fields failed validation. |
| `AUTH_REQUIRED` | 401 | No user bearer token was provided. |
| `AUTH_INVALID` | 401 | Token is expired, malformed, revoked, or from another project. |
| `REAUTH_REQUIRED` | 401 | A recent sign-in is required for a sensitive operation. |
| `FORBIDDEN` | 403 | Caller cannot access the requested resource. |
| `ADMIN_REQUIRED` | 403 | Caller is authenticated but is not an active admin. |
| `ENTITLEMENT_REQUIRED` | 403 | The lifetime free demo is unavailable and active beta or paid access is required. |
| `AI_CONSENT_REQUIRED` | 403 | Current AI-processing disclosure has not been accepted. |
| `DIAGNOSTIC_ALREADY_USED` | 403 | The account has already claimed its one lifetime 20-word diagnostic demo. |
| `NOT_FOUND` | 404 | Resource was not found or is hidden by ownership rules. |
| `IDEMPOTENCY_CONFLICT` | 409 | Idempotency key was reused with different input. |
| `CONFIG_VERSION_MISMATCH` | 409 | Client submitted an obsolete or unknown WAT configuration. |
| `SESSION_STATE_CONFLICT` | 409 | Operation is not permitted in the current session state. |
| `SESSION_ALREADY_FINISHED` | 409 | Session has already been finalized. |
| `SESSION_NOT_FINISHED` | 409 | Operation requires a finished session. |
| `SESSION_LATE_ANSWER` | 409 | Simulation answer arrived after its deadline plus grace. |
| `ANSWER_NOT_ACTIVE` | 409 | Simulation answer was submitted before that position opened. |
| `ANSWER_ALREADY_LOCKED` | 409 | A locked answer cannot be replaced. |
| `OCR_CONFIRMATION_STALE` | 409 | OCR draft changed or was re-run after the displayed revision. |
| `REPORT_ALREADY_EXISTS` | 409 | A final report already exists for the session. |
| `PAYMENT_PENDING_EXISTS` | 409 | User already has a pending payment submission. |
| `TRANSACTION_ID_EXISTS` | 409 | Provider and transaction ID combination has already been submitted. |
| `PAYMENT_ALREADY_DECIDED` | 409 | Payment is no longer pending. |
| `PAYMENT_OFFER_INACTIVE` | 409 | Selected offer is not currently available. |
| `DATA_EXPORT_IN_PROGRESS` | 409 | User already has an active export job. |
| `SESSION_EXPIRED` | 410 | Started session can no longer accept writes. |
| `UPLOAD_EXPIRED` | 410 | Signed upload or unconfirmed paper upload expired. |
| `UPLOAD_TOO_LARGE` | 413 | Image or total upload exceeds configured limits. |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | Only supported image formats are accepted. |
| `PAPER_UPLOAD_INCOMPLETE` | 422 | Required pages are missing, duplicated, or unordered. |
| `OCR_TEXT_INCOMPLETE` | 422 | Confirmation must contain every session position. |
| `REPORT_LIMIT_REACHED` | 429 | Three reports already started or completed in the rolling window. |
| `RATE_LIMITED` | 429 | Endpoint-specific request rate exceeded. |
| `OCR_FAILED` | 502 | OCR provider completed but returned an unusable result. |
| `AI_OUTPUT_INVALID` | 502 | Feedback remained invalid after the controlled retry. |
| `PROVIDER_UNAVAILABLE` | 503 | OCR, AI, email, database, or Storage dependency is unavailable. |
| `FEATURE_DISABLED` | 503 | Administrator disabled this feature. |
| `GLOBAL_QUOTA_EXHAUSTED` | 503 | Application-level free-tier safety cap was reached. |
| `INTERNAL_ERROR` | 500 | Unexpected backend error. |

Ownership failures normally return `NOT_FOUND`, rather than confirming that
another user's resource exists.

---

## 3. Configuration constants

These defaults are versioned backend configuration. A client may display values
returned by `/config/wat`, but must not treat local constants as authoritative.

| Constant | v1 value | Rule |
|---|---:|---|
| `API_VERSION` | `1` | Public contract version |
| `WAT_SCHEMA_VERSION` | `1` | Session payload schema |
| `WAT_ALLOWED_SESSION_SIZES` | `[20]` | Exactly 20 words in v1 |
| `WAT_SECONDS_PER_WORD` | `15` | Simulation display duration |
| `ANSWER_GRACE_MS` | `2000` | Transport grace; UI still shows 15 seconds |
| `ANSWER_MAX_CHARS` | `280` | Unicode code points after normalization |
| `SESSION_WRITE_TTL_MINUTES` | `30` | Unfinished server session expiry |
| `HISTORY_DEFAULT_LIMIT` | `20` | Default page size |
| `HISTORY_MAX_LIMIT` | `100` | Maximum page size |
| `PAPER_MAX_PAGES` | `4` | Maximum ordered page images |
| `PAPER_MAX_IMAGE_BYTES` | `8388608` | 8 MiB per re-encoded image |
| `PAPER_MAX_TOTAL_BYTES` | `25165824` | 24 MiB per session |
| `PAPER_ALLOWED_MIME_TYPES` | `image/jpeg`, `image/png`, `image/webp` | Server verifies magic bytes |
| `SIGNED_UPLOAD_TTL_SECONDS` | `900` | Upload URL validity |
| `UNCONFIRMED_UPLOAD_TTL_HOURS` | `24` | Abandoned-image deletion deadline |
| `REPORTS_PER_ROLLING_WINDOW` | `3` | Beta/paid account report limit |
| `REPORT_WINDOW_HOURS` | `24` | Rolling window, not calendar day |
| `FREE_DIAGNOSTIC_SESSIONS` | `1` | Lifetime authenticated 20-word demo sessions per account |
| `FREE_DIAGNOSTIC_REPORTS` | `1` | One final report tied to the lifetime free demo |
| `OCR_MONTHLY_APP_CAP` | `900` | Safety cap below the provider's free allowance |
| `AI_PROVIDER_MAX_ATTEMPTS` | `2` | Initial request plus one controlled retry |
| `OCR_PROVIDER_MAX_ATTEMPTS` | `3` | Exponential backoff for transient failures |
| `PAYMENT_TRANSACTION_ID_MAX_CHARS` | `100` | Normalized external transaction ID |
| `PAID_ACCESS_DAYS` | `30` | Manual founding-plan entitlement |
| `RECENT_AUTH_MAX_AGE_MINUTES` | `10` | Required for account deletion |
| `EXPORT_DOWNLOAD_TTL_MINUTES` | `10` | Signed export URL validity |
| `EXPORT_RETENTION_HOURS` | `24` | Generated export auto-deletion |

### 3.1 Simulation late-answer rule

For position `n` in a 20-word simulation:

```text
opens_at    = session.started_at + ((n - 1) * 15 seconds)
deadline_at = session.started_at + (n * 15 seconds)
accept_until = deadline_at + 2 seconds transport grace
```

An answer received before `opens_at` returns `ANSWER_NOT_ACTIVE`. An answer
received after `accept_until` returns `SESSION_LATE_ANSWER`. The two-second
grace is not displayed as candidate response time and does not extend the UI
timer. Server receive time is authoritative.

Training mode permits pause, retry, and manual next behavior, so strict
server-clock late rejection does not apply. Training answers are still locked
when the session finishes.

### 3.2 Free demo, entitlement, and report rules

- While `beta_open=true`, a `beta` entitlement is issued on first authenticated
  use and permits additional sessions plus three report requests per rolling 24
  hours. Public beta is an explicit administrative exception to the normal
  free-demo limit and should remain disabled when the one-demo paywall is in
  effect for all candidates.
- Outside beta, an account without paid access may create exactly one lifetime
  authenticated, server-tracked `diagnostic` demo. It always uses the current
  published diagnostic set and exactly 20 words, and includes one final report
  for that same session.
- Creating the free demo claims the account's lifetime session allowance in the
  same transaction. A different idempotency key, browser, device, practice
  mode, response mode, imported session, or deleted local browser state must
  not create another free demo.
- An unfinished free demo remains the same canonical session and may be resumed
  while writable. Starting again returns that session rather than creating a
  second free session. Accepted answers and their timing remain unchanged.
- A verified server, network, OCR, Storage, or feedback-provider failure may
  extend or retry the affected operation on the same canonical demo. It must
  not create a second demo, erase accepted answers, or consume a second free
  report. User abandonment, intentional restart, or ordinary inactivity is not
  a technical failure.
- Guest and legacy sessions may be imported into history, but they neither
  claim nor replace the authenticated free demo. Without active beta or paid
  access, imported sessions are not eligible for feedback.
- An active `founding_30d` entitlement permits three reports per rolling 24
  hours until `expires_at` and permits additional 20-word server sessions.
- In-progress and successful report jobs consume a slot. A terminal provider
  failure releases the reservation so the same eligible session can be retried.
- OCR alone does not consume a report slot. It does consume the global OCR
  safety counter per provider page request.
- The owner may continue to read the completed free demo, its answers, and its
  final report after the demo allowance is used or a paid entitlement expires,
  until the owner deletes the account or the data under a future retention rule.

### 3.3 Pre-demo price and access disclosure

Before the candidate confirms and starts the free demo, the client must show:

- that the demo contains exactly 20 words and is available once per account;
- that it includes one report and cannot be restarted merely to obtain a new
  word set or another report;
- that an unfinished demo can be resumed and verified technical failures can be
  retried on the same session;
- the current active paid offer's exact price, currency, access duration, and
  concrete benefits; and
- that completed demo results remain readable after the free allowance is used.

The client obtains price and benefits from `GET /payment-offers`; it must not
hard-code them. If no active offer is returned, the client states that paid
access is currently unavailable instead of displaying a stale price. Starting
the demo requires an explicit confirmation after this disclosure.

---

## 4. System and account endpoints

### 4.1 Health check

#### `GET /health`

**Caller:** Public  
**Request:** No body

**Response — `200 OK`**

```json
{
  "data": {
    "status": "ok",
    "api_version": "v1",
    "release": "2026.10.0",
    "database": "up",
    "time": "2026-10-02T09:30:00Z"
  }
}
```

If the database cannot be reached, return `503 PROVIDER_UNAVAILABLE` with no
connection details. This endpoint does not call Google Vision or Gemini.

**Errors:** `PROVIDER_UNAVAILABLE`, `INTERNAL_ERROR`

**Business rules:** Do not expose project references, secrets, table names,
provider quotas, or stack traces.

---

### 4.2 Get current account

#### `GET /me`

**Caller:** Authenticated user  
**Request:** No body

**Response — `200 OK`**

```json
{
  "data": {
    "id": "ba27fbf1-0ce7-4f82-b9d2-e6c76b78f031",
    "email": "candidate@example.com",
    "display_name": "A. Khan",
    "timezone": "Asia/Karachi",
    "role": "candidate",
    "ai_processing_consent": {
      "accepted": true,
      "version": "2026-10-01",
      "accepted_at": "2026-10-02T09:15:00Z"
    },
    "entitlement": null,
    "free_demo": {
      "status": "completed",
      "session_id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
      "report_status": "ready",
      "can_start": false,
      "can_resume": false,
      "can_retry_technical_failure": false
    },
    "usage": {
      "free_demo_sessions_used_lifetime": 1,
      "free_demo_sessions_remaining_lifetime": 0,
      "free_reports_used_lifetime": 1,
      "free_reports_remaining_lifetime": 0,
      "reports_used_rolling_24h": 0,
      "reports_remaining_rolling_24h": 0,
      "next_slot_releases_at": null
    },
    "features": {
      "ocr_enabled": true,
      "feedback_enabled": true,
      "payments_enabled": true,
      "beta_open": false
    },
    "created_at": "2026-10-02T09:10:00Z"
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `INTERNAL_ERROR`

**Business rules:**

- `role` is derived server-side.
- Expired entitlements are returned with `status: "expired"`.
- Lifetime and rolling usage values are derived server-side. For an account
  without active beta or paid access, rolling report allowance is zero after
  its one free-demo report is used.
- `free_demo.status` is `available`, `in_progress`, `completed`, or
  `technical_failure`. The session and report IDs are returned only for the
  caller's own demo. Retry eligibility is determined by trusted server failure
  state, never a client-supplied flag.
- Email changes occur through Supabase Auth, not `PATCH /me`.

---

### 4.3 Update current account

#### `PATCH /me`

**Caller:** Authenticated user

**Request**

```json
{
  "display_name": "Ahmed Khan",
  "timezone": "Asia/Karachi",
  "accept_ai_processing_terms_version": "2026-10-01"
}
```

Every field is optional, but at least one must be present.

**Response — `200 OK`**

Returns the same account object as `GET /me`.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `VALIDATION_ERROR`,
`INTERNAL_ERROR`

**Business rules:**

- `display_name` is 1-80 trimmed characters.
- `timezone` must be a valid IANA timezone.
- Consent can only accept the current published version through this endpoint.
  Withdrawal is handled by disabling future AI processing in account settings;
  previously generated reports remain until deleted by the user.
- Clients cannot change `role`, `entitlement`, limits, email, or usage.

---

### 4.4 Get WAT configuration

#### `GET /config/wat?kind=diagnostic|practice`

**Caller:** Public

**Response — `200 OK`**

```json
{
  "data": {
    "schema_version": 1,
    "set": {
      "id": "7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1",
      "code": "diagnostic-v1",
      "version": 1,
      "kind": "diagnostic"
    },
    "rules": {
      "total_words": 20,
      "seconds_per_word": 15,
      "answer_max_chars": 280,
      "answer_grace_ms": 2000
    },
    "free_demo": {
      "requires_authentication": true,
      "lifetime_sessions_per_account": 1,
      "includes_reports": 1
    },
    "words": [
      { "position": 1, "word": "Courage" },
      { "position": 2, "word": "Failure" }
    ]
  }
}
```

The example is shortened; the real response contains all 20 words.

**Errors:** `INVALID_REQUEST`, `FEATURE_DISABLED`, `INTERNAL_ERROR`

**Business rules:**

- The returned set is immutable for its version.
- Clients save `set.id` and `set.version` with local sessions.
- Guest practice may use this configuration locally. Cloud save, OCR, reports,
  progress, and history require authentication.
- Public configuration describes the free-demo terms but cannot determine a
  caller's eligibility. Authenticated clients use `GET /me` for that decision.

---

## 5. WAT session endpoints

### 5.1 Start a server-tracked WAT session

#### `POST /wat/sessions`

**Caller:** Authenticated user  
**Header:** `Idempotency-Key` required

**Request**

```json
{
  "client_session_id": "browser-8f72ea1e-312c-4fda-9c22-f970e97b4cc7",
  "set_id": "7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1",
  "set_version": 1,
  "kind": "diagnostic",
  "practice_mode": "simulation",
  "response_mode": "typing",
  "session_size": 20
}
```

**Response — `201 Created`**

```json
{
  "data": {
    "id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
    "status": "in_progress",
    "resumed": false,
    "schema_version": 1,
    "kind": "diagnostic",
    "practice_mode": "simulation",
    "response_mode": "typing",
    "started_at": "2026-10-02T09:30:00Z",
    "expires_at": "2026-10-02T10:00:00Z",
    "rules": {
      "total_words": 20,
      "seconds_per_word": 15,
      "answer_grace_ms": 2000,
      "answer_max_chars": 280
    },
    "items": [
      {
        "position": 1,
        "word": "Courage",
        "opens_at": "2026-10-02T09:30:00Z",
        "deadline_at": "2026-10-02T09:30:15Z"
      },
      {
        "position": 2,
        "word": "Failure",
        "opens_at": "2026-10-02T09:30:15Z",
        "deadline_at": "2026-10-02T09:30:30Z"
      }
    ]
  }
}
```

The example is shortened; `items` contains all 20 positions.

If the caller already has an unfinished free demo, return `200 OK` with that
same session, `resumed: true`, its accepted answers, and its current writable
expiry. Do not create another session.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `VALIDATION_ERROR`,
`CONFIG_VERSION_MISMATCH`, `ENTITLEMENT_REQUIRED`,
`DIAGNOSTIC_ALREADY_USED`, `IDEMPOTENCY_CONFLICT`, `RATE_LIMITED`,
`FEATURE_DISABLED`, `INTERNAL_ERROR`

**Business rules:**

- `practice_mode` is `training` or `simulation`.
- `response_mode` is `typing` or `paper`.
- `kind` is `diagnostic` or `practice`.
- A caller without active beta or paid access may start only the single free
  `diagnostic` demo. `practice` and additional `diagnostic` sessions require an
  active entitlement.
- The free demo always contains exactly 20 words. Session creation and the
  lifetime claim must commit in one transaction under a database uniqueness
  guarantee so concurrent requests cannot create two demos.
- Reopening the start screen, changing devices, or using another idempotency key
  returns the existing unfinished free demo. A previously completed, abandoned,
  or ordinarily expired demo returns `DIAGNOSTIC_ALREADY_USED`.
- A trusted service may extend the same demo's writable expiry after a verified
  platform outage. This recovery never changes its ID, word snapshots, accepted
  answers, or original `started_at`.
- A user may have only one `in_progress` server session at a time. Starting a
  new one requires finishing or abandoning the previous session.
- Server snapshots the words so future word-bank edits never change history.
- `started_at` and all simulation deadlines use server time.
- Returning all words is a delivery optimization, not an exam-security claim.
  The backend still rejects early or late simulation writes.

---

### 5.2 Save one typed answer

#### `PUT /wat/sessions/{session_id}/answers/{position}`

**Caller:** Authenticated session owner

**Request**

```json
{
  "answer": "Courage helps a person act despite fear.",
  "client_elapsed_ms": 11240,
  "client_saved_at": "2026-10-02T09:30:11.240Z",
  "advance_reason": "timer"
}
```

`advance_reason` is `timer`, `next`, `session_end`, or `autosave`.

**Response — `200 OK`**

```json
{
  "data": {
    "session_id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
    "position": 1,
    "saved": true,
    "locked": true,
    "answer": "Courage helps a person act despite fear.",
    "time_used_ms": 11240,
    "received_at": "2026-10-02T09:30:11.410Z"
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`VALIDATION_ERROR`, `SESSION_STATE_CONFLICT`, `SESSION_ALREADY_FINISHED`,
`SESSION_EXPIRED`, `ANSWER_NOT_ACTIVE`, `SESSION_LATE_ANSWER`,
`ANSWER_ALREADY_LOCKED`, `RATE_LIMITED`, `INTERNAL_ERROR`

**Business rules:**

- `answer` may be blank, but cannot exceed 280 Unicode code points.
- Normalize line endings and Unicode to NFC; preserve candidate wording and
  capitalization otherwise.
- Simulation answers become write-once and locked when first accepted.
- Simulation receive time determines early/late acceptance. Client timestamps
  never override the server clock.
- Training mode may update the current answer before session finish. Retry and
  pause behavior is recorded as client telemetry but does not change official
  server time rules because training is not strict simulation.
- Paper sessions cannot call this endpoint.

---

### 5.3 Finish a WAT session

#### `POST /wat/sessions/{session_id}/finish`

**Caller:** Authenticated session owner  
**Header:** `Idempotency-Key` required

**Request**

```json
{
  "reason": "natural",
  "client_completed_at": "2026-10-02T09:35:00Z"
}
```

`reason` is `natural` or `manual`.

**Response — `200 OK`**

```json
{
  "data": {
    "id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
    "status": "finished",
    "finished_at": "2026-10-02T09:35:00.210Z",
    "ended_early": false,
    "next_action": "generate_report",
    "statistics": {
      "total_words": 20,
      "completed_words": 20,
      "answered_words": 18,
      "blank_words": 2,
      "average_response_seconds": 11.8
    }
  }
}
```

For paper mode, `status` becomes `awaiting_upload`, and `next_action` is
`upload_paper_pages`.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`SESSION_ALREADY_FINISHED`, `SESSION_EXPIRED`, `IDEMPOTENCY_CONFLICT`,
`INTERNAL_ERROR`

**Business rules:**

- Server `finished_at` is canonical.
- Missing simulation answers are recorded as blank after their windows close.
- Manual finish locks accepted typed answers and marks `ended_early=true` when
  fewer than 20 positions completed.
- Finishing a session does not automatically consume report quota.
- Finishing the free demo permanently uses its session allowance. The owner may
  still read this session and its eventual report without an active entitlement.

---

### 5.4 Import a completed guest or legacy session

#### `POST /wat/sessions/import`

**Caller:** Authenticated user  
**Header:** `Idempotency-Key` required

**Request**

```json
{
  "schema_version": 1,
  "client_session_id": "wat-guest-1727859000000",
  "source": "guest_local",
  "set_code": "diagnostic-v1",
  "set_version": 1,
  "kind": "diagnostic",
  "practice_mode": "training",
  "response_mode": "typing",
  "started_at": "2026-10-02T09:30:00Z",
  "completed_at": "2026-10-02T09:34:20Z",
  "ended_early": false,
  "responses": [
    {
      "position": 1,
      "word": "Courage",
      "answer": "Courage helps a person act despite fear.",
      "completed": true,
      "time_used_ms": 11240
    }
  ]
}
```

The real request must contain all 20 response positions, including blanks and
not-attempted positions.

**Response — `201 Created`**

```json
{
  "data": {
    "id": "c81130cd-bc32-45a5-954e-4c67fd50c147",
    "status": "finished",
    "source": "guest_local",
    "timing_trust": "client_reported",
    "eligible_for_feedback": false,
    "imported_at": "2026-10-02T09:40:00Z"
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `VALIDATION_ERROR`,
`CONFIG_VERSION_MISMATCH`, `ENTITLEMENT_REQUIRED`, `IDEMPOTENCY_CONFLICT`,
`RATE_LIMITED`, `INTERNAL_ERROR`

**Business rules:**

- `source` is `guest_local` or `legacy_local_storage`.
- Imported timestamps and response times are marked client-reported and are
  never represented as server-verified simulation timing.
- Import does not automatically generate a report or consume quota.
- Import never claims, replaces, or resets the account's free demo. An imported
  session requires active beta or paid access to be eligible for feedback.
- Duplicate `(user_id, client_session_id)` imports return the existing session.
- A legacy paper session with no captured text remains activity-only and is not
  eligible for feedback.
- Bulk legacy migration calls this endpoint in frontend-controlled chunks; a
  single request imports one session to keep idempotency clear.

---

### 5.5 Get one session

#### `GET /wat/sessions/{session_id}`

**Caller:** Authenticated session owner

**Response — `200 OK`**

```json
{
  "data": {
    "id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
    "schema_version": 1,
    "kind": "diagnostic",
    "status": "ready",
    "practice_mode": "simulation",
    "response_mode": "typing",
    "source": "server",
    "timing_trust": "server_verified",
    "started_at": "2026-10-02T09:30:00Z",
    "finished_at": "2026-10-02T09:35:00.210Z",
    "ended_early": false,
    "set": {
      "code": "diagnostic-v1",
      "version": 1
    },
    "responses": [
      {
        "position": 1,
        "word": "Courage",
        "answer": "Courage helps a person act despite fear.",
        "source": "typed",
        "status": "answered",
        "time_used_ms": 11240
      }
    ],
    "ocr": null,
    "report": {
      "id": "969924db-9a7f-4687-b0ac-a795c2fc0d3c",
      "status": "ready"
    }
  }
}
```

The example response list is shortened.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`, `INTERNAL_ERROR`

**Business rules:** Provider raw responses, Storage paths, and deleted image
metadata are never returned. Reading an owned historical session never requires
a currently active entitlement, including after the free demo is used or paid
access expires.

---

### 5.6 List session history

#### `GET /wat/sessions`

**Caller:** Authenticated user

**Query parameters**

| Parameter | Values |
|---|---|
| `limit` | `1`-`100`, default `20` |
| `cursor` | Opaque cursor |
| `kind` | `diagnostic`, `practice` |
| `practice_mode` | `training`, `simulation` |
| `response_mode` | `typing`, `paper` |
| `status` | `in_progress`, `finished`, `awaiting_upload`, `ocr_processing`, `awaiting_confirmation`, `feedback_processing`, `ready`, `failed` |
| `from` | RFC 3339 lower bound |
| `to` | RFC 3339 upper bound |

**Response — `200 OK`**

```json
{
  "data": [
    {
      "id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
      "kind": "diagnostic",
      "status": "ready",
      "practice_mode": "simulation",
      "response_mode": "typing",
      "started_at": "2026-10-02T09:30:00Z",
      "finished_at": "2026-10-02T09:35:00.210Z",
      "completed_words": 20,
      "answered_words": 18,
      "completion_percent": 100,
      "average_response_seconds": 11.8,
      "report_score": 8.2
    }
  ],
  "meta": {
    "next_cursor": "eyJmaW5pc2hlZF9hdCI6Ii4uLiJ9",
    "has_more": true
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `VALIDATION_ERROR`,
`INTERNAL_ERROR`

**Business rules:** The endpoint returns summary rows only. Use the get-one and
report endpoints for detailed responses and feedback. Owned history remains
readable after the free demo is used or paid access expires.

---

## 6. Paper mode and OCR endpoints

### 6.1 Prepare private paper-page uploads

#### `POST /wat/sessions/{session_id}/paper/uploads`

**Caller:** Authenticated session owner

**Request**

```json
{
  "files": [
    {
      "page_number": 1,
      "file_name": "page-1.jpg",
      "content_type": "image/jpeg",
      "size_bytes": 2458120,
      "sha256": "4f64c92d0e70c93d75f676d9f580dc3a35eec78de9f883944902b5216ad98a8b"
    },
    {
      "page_number": 2,
      "file_name": "page-2.jpg",
      "content_type": "image/jpeg",
      "size_bytes": 2310112,
      "sha256": "6ce78452552f078b6a2e5b79c7fdd32ee9ca29491e1096f42e239f4de62c2cb7"
    }
  ]
}
```

**Response — `201 Created`**

```json
{
  "data": {
    "session_id": "94a9fa5b-4eed-4dda-809c-f111990be91d",
    "uploads": [
      {
        "upload_id": "c68d66a9-0ecf-43ba-9e6a-6f6c32f447ea",
        "page_number": 1,
        "method": "PUT",
        "upload_url": "https://<project-ref>.supabase.co/storage/v1/upload/resumable/...",
        "required_headers": {
          "content-type": "image/jpeg"
        },
        "expires_at": "2026-10-02T10:00:00Z"
      }
    ]
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`SESSION_NOT_FINISHED`, `SESSION_STATE_CONFLICT`, `VALIDATION_ERROR`,
`UPLOAD_TOO_LARGE`, `UNSUPPORTED_MEDIA_TYPE`, `FEATURE_DISABLED`,
`RATE_LIMITED`, `INTERNAL_ERROR`

**Business rules:**

- Only finished paper sessions may prepare uploads.
- Accept 1-4 pages with unique contiguous page numbers starting at 1.
- The frontend re-encodes camera images to JPEG/PNG/WebP, removes EXIF, and
  reduces dimensions before requesting an upload.
- The backend verifies declared type, size, object path, actual Storage size,
  magic bytes, and checksum before OCR.
- The bucket is private. Upload authorization does not grant read access.
- URLs expire after 15 minutes. Unconfirmed objects expire after 24 hours.

---

### 6.2 Start OCR for uploaded pages

#### `POST /wat/sessions/{session_id}/paper/ocr`

**Caller:** Authenticated session owner  
**Header:** `Idempotency-Key` required

**Request**

```json
{
  "upload_ids": [
    "c68d66a9-0ecf-43ba-9e6a-6f6c32f447ea",
    "3afbf00c-a311-4338-9524-687c33eea453"
  ],
  "language": "en"
}
```

Order is page order.

**Response — `202 Accepted`**

```json
{
  "data": {
    "job_id": "5107089a-37a9-4030-929f-3c48465fc064",
    "session_id": "94a9fa5b-4eed-4dda-809c-f111990be91d",
    "type": "ocr",
    "status": "queued",
    "poll_after_ms": 2000
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`SESSION_STATE_CONFLICT`, `PAPER_UPLOAD_INCOMPLETE`, `UPLOAD_EXPIRED`,
`UPLOAD_TOO_LARGE`, `UNSUPPORTED_MEDIA_TYPE`, `IDEMPOTENCY_CONFLICT`,
`FEATURE_DISABLED`, `GLOBAL_QUOTA_EXHAUSTED`, `RATE_LIMITED`,
`INTERNAL_ERROR`

**Business rules:**

- Use Google Cloud Vision `DOCUMENT_TEXT_DETECTION` with English handwriting
  hints for v1.
- Each provider page request increments the monthly application OCR counter.
- Starting OCR is idempotent for the same ordered uploads.
- Job state is durable. A background task may begin immediately, while the
  scheduled job runner recovers abandoned queued/retryable work.
- A terminal OCR failure does not delete images immediately; the candidate may
  retry until the 24-hour upload expiry.

---

### 6.3 Get asynchronous job status

#### `GET /jobs/{job_id}`

**Caller:** Authenticated job owner; admins may read operational fields

**Response — `200 OK`**

```json
{
  "data": {
    "id": "5107089a-37a9-4030-929f-3c48465fc064",
    "type": "ocr",
    "status": "succeeded",
    "attempt": 1,
    "created_at": "2026-10-02T09:46:00Z",
    "started_at": "2026-10-02T09:46:00.190Z",
    "completed_at": "2026-10-02T09:46:07.430Z",
    "result": {
      "session_id": "94a9fa5b-4eed-4dda-809c-f111990be91d",
      "next_action": "confirm_ocr",
      "ocr_revision": 1
    },
    "error": null
  }
}
```

Failed jobs return a safe result such as:

```json
{
  "data": {
    "id": "5107089a-37a9-4030-929f-3c48465fc064",
    "type": "ocr",
    "status": "failed",
    "attempt": 3,
    "error": {
      "code": "OCR_FAILED",
      "message": "We could not read these pages. Retake clear, well-lit photos and try again."
    }
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`, `INTERNAL_ERROR`

**Business rules:**

- `status` is `queued`, `processing`, `retrying`, `succeeded`, or `failed`.
- Provider payloads, tokens, and stack traces are never returned.
- Clients poll at `poll_after_ms`, then use exponential backoff capped at 10
  seconds.

---

### 6.4 Get OCR draft

#### `GET /wat/sessions/{session_id}/paper/ocr`

**Caller:** Authenticated session owner

**Response — `200 OK`**

```json
{
  "data": {
    "session_id": "94a9fa5b-4eed-4dda-809c-f111990be91d",
    "status": "awaiting_confirmation",
    "ocr_revision": 1,
    "responses": [
      {
        "position": 1,
        "word": "Courage",
        "ocr_text": "Courage helps us face fear.",
        "confidence": 0.91,
        "needs_review": false
      },
      {
        "position": 2,
        "word": "Failure",
        "ocr_text": "",
        "confidence": null,
        "needs_review": true
      }
    ]
  }
}
```

The real response contains exactly 20 entries.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`SESSION_STATE_CONFLICT`, `OCR_FAILED`, `INTERNAL_ERROR`

**Business rules:**

- OCR text is always a draft, never canonical candidate text.
- Missing, low-confidence, duplicated, or ambiguously mapped lines set
  `needs_review=true`.
- Confidence is advisory and may be `null` when the provider has no reliable
  aggregate value.

---

### 6.5 Confirm corrected OCR text

#### `PUT /wat/sessions/{session_id}/paper/confirm`

**Caller:** Authenticated session owner

**Request**

```json
{
  "ocr_revision": 1,
  "responses": [
    {
      "position": 1,
      "confirmed_text": "Courage helps us face fear."
    },
    {
      "position": 2,
      "confirmed_text": "Failure teaches a person to improve."
    }
  ]
}
```

The real request contains each position from 1 through 20 exactly once.
`confirmed_text` may be blank.

**Response — `200 OK`**

```json
{
  "data": {
    "session_id": "94a9fa5b-4eed-4dda-809c-f111990be91d",
    "status": "finished",
    "confirmed_at": "2026-10-02T09:50:00Z",
    "images": {
      "status": "deleted",
      "delete_pending": false
    },
    "next_action": "generate_report"
  }
}
```

If Storage deletion is temporarily unavailable, confirmation still succeeds
and returns `status: "delete_pending"`; the cleanup job retries deletion.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`SESSION_STATE_CONFLICT`, `OCR_CONFIRMATION_STALE`, `OCR_TEXT_INCOMPLETE`,
`VALIDATION_ERROR`, `INTERNAL_ERROR`

**Business rules:**

- Candidate confirmation is mandatory, even when every OCR confidence is high.
- Confirmation replaces OCR draft text with canonical candidate-confirmed text.
- Original images are deleted immediately after successful confirmation.
- Raw provider response is not retained after confirmation. Minimal OCR quality
  metrics may be retained without image or text content.
- Re-running OCR increments `ocr_revision`; stale screens cannot overwrite the
  new draft.

---

## 7. Report endpoints

### 7.1 Generate report

#### `POST /wat/sessions/{session_id}/report`

**Caller:** Authenticated session owner  
**Header:** `Idempotency-Key` required

**Request**

```json
{
  "rubric_version": "wat-rubric-v1"
}
```

**Response — `202 Accepted`**

```json
{
  "data": {
    "job_id": "24b5179e-f535-4d20-83c0-6925d2ea4b7e",
    "session_id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
    "type": "feedback",
    "status": "queued",
    "quota": {
      "used_rolling_24h": 2,
      "remaining_rolling_24h": 1
    },
    "poll_after_ms": 2000
  }
}
```

If a job already exists, return its current state. If a final report already
exists and the same idempotency key is used, return `200 OK` with the report
reference.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`SESSION_NOT_FINISHED`, `SESSION_STATE_CONFLICT`, `AI_CONSENT_REQUIRED`,
`ENTITLEMENT_REQUIRED`, `DIAGNOSTIC_ALREADY_USED`, `REPORT_LIMIT_REACHED`,
`REPORT_ALREADY_EXISTS`, `IDEMPOTENCY_CONFLICT`, `FEATURE_DISABLED`,
`GLOBAL_QUOTA_EXHAUSTED`, `RATE_LIMITED`, `INTERNAL_ERROR`

**Business rules:**

- Typed answers or candidate-confirmed paper text must exist.
- Without active beta or paid access, report generation is permitted only for
  the account's canonical free-demo session and only until that session has one
  final report. Imported and additional sessions do not qualify.
- A terminal infrastructure or provider failure releases the free-report
  reservation. The owner may retry report generation for the same demo; the
  retry must reuse the same session and cannot create a second final report.
- Send Gemini only ordered word/answer pairs and rubric instructions. Do not
  send email, display name, payment data, image, exact date, or user ID.
- Candidate text is delimited and treated as untrusted data, never as model
  instructions.
- Gemini must return the configured structured schema. The backend validates
  position count, score bounds, enums, and text lengths.
- One controlled retry is allowed for invalid model output.
- Backend derives display scores from integer rubric ratings. Gemini does not
  directly decide the final session score.
- Report generation must not claim diagnosis, official assessment, or selection
  likelihood.

---

### 7.2 Fetch report

#### `GET /wat/sessions/{session_id}/report`

**Caller:** Authenticated session owner

**Response — `200 OK`**

```json
{
  "data": {
    "id": "969924db-9a7f-4687-b0ac-a795c2fc0d3c",
    "session_id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
    "status": "ready",
    "rubric_version": "wat-rubric-v1",
    "prompt_version": "wat-feedback-2026-10-01",
    "model": {
      "provider": "google_gemini",
      "name": "gemini-3.5-flash-lite"
    },
    "generated_at": "2026-10-02T09:36:20Z",
    "score": {
      "overall": 8.2,
      "maximum": 10.0,
      "label": "Strong practice response pattern"
    },
    "dimensions": {
      "tone": {
        "score": 8.4,
        "maximum": 10.0,
        "label": "Constructive"
      },
      "agency": {
        "score": 7.8,
        "maximum": 10.0,
        "label": "Active"
      },
      "clarity": {
        "score": 8.8,
        "maximum": 10.0,
        "label": "Clear"
      },
      "realism": {
        "score": 7.8,
        "maximum": 10.0,
        "label": "Grounded"
      }
    },
    "sentences": [
      {
        "position": 1,
        "word": "Courage",
        "response": "Courage helps a person act despite fear.",
        "response_source": "typed",
        "status": "scored",
        "score": 8.5,
        "ratings": {
          "tone": {
            "rating": 4,
            "maximum": 5,
            "label": "constructive",
            "note": "The sentence frames courage positively without exaggeration."
          },
          "agency": {
            "rating": 4,
            "maximum": 5,
            "label": "active",
            "note": "It describes action despite fear."
          },
          "clarity": {
            "rating": 5,
            "maximum": 5,
            "label": "clear",
            "note": "The idea is complete and easy to understand."
          },
          "realism": {
            "rating": 4,
            "maximum": 5,
            "label": "grounded",
            "note": "The claim is practical and believable."
          }
        },
        "strength": "It connects courage with action rather than absence of fear.",
        "feedback": "Make the sentence more specific by naming a situation in which the person acts.",
        "safety_flags": []
      },
      {
        "position": 2,
        "word": "Failure",
        "response": "",
        "response_source": "typed",
        "status": "not_scored",
        "score": null,
        "ratings": null,
        "strength": null,
        "feedback": "No response was recorded.",
        "safety_flags": []
      }
    ],
    "summary": {
      "narrative": "Responses are generally clear and constructive, with the strongest pattern in practical framing.",
      "strengths": [
        {
          "code": "CLEAR_EXPRESSION",
          "label": "Clear expression",
          "evidence_positions": [1, 4, 8]
        }
      ],
      "weak_areas": [
        {
          "code": "LOW_SPECIFICITY",
          "label": "Responses can be too general",
          "evidence_positions": [3, 7, 11],
          "recommendation": "Use a concrete actor and action when the word allows it."
        }
      ],
      "next_drill": {
        "code": "ACTOR_ACTION_DRILL",
        "title": "Actor and action drill",
        "instructions": "Write ten short responses that identify who acts and what they do.",
        "recommended_items": 10
      }
    },
    "disclaimer": "This is AI-assisted practice feedback, not an official ISSB assessment, psychological evaluation, or selection prediction."
  }
}
```

The example contains two sentence entries; a complete report contains all 20.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`SESSION_STATE_CONFLICT`, `AI_OUTPUT_INVALID`, `INTERNAL_ERROR`

**Business rules:**

- Ratings are integers `1`-`5`; displayed dimension scores are deterministically
  converted to `0`-`10` values by the backend.
- Blank or not-attempted responses are included with `status=not_scored` and do
  not affect rubric averages.
- `response_source` is `typed`, `ocr_confirmed`, or `legacy_typed`.
- `safety_flags` may contain `self_harm`, `violence`, or `other_sensitive`. A
  flag triggers safe supportive wording; it does not diagnose the candidate.
- Raw model output and hidden prompts are not returned.
- Fetching an owned report never requires a currently active entitlement. The
  free-demo report remains readable after the demo is used, and paid reports
  remain readable after paid access expires.

---

## 8. Progress endpoint

### 8.1 Get progress and trends

#### `GET /progress?range=30d&compare=previous_period`

**Caller:** Authenticated user

**Query parameters**

| Parameter | Values | Default |
|---|---|---|
| `range` | `7d`, `30d`, `90d`, `all` | `30d` |
| `compare` | `none`, `previous_period` | `previous_period` |
| `practice_mode` | `all`, `training`, `simulation` | `all` |
| `response_mode` | `all`, `typing`, `paper` | `all` |

**Response — `200 OK`**

```json
{
  "data": {
    "range": {
      "key": "30d",
      "from": "2026-09-03T00:00:00+05:00",
      "to": "2026-10-03T00:00:00+05:00",
      "timezone": "Asia/Karachi"
    },
    "totals": {
      "sessions": 8,
      "completed_sessions": 7,
      "words_presented": 160,
      "answers_recorded": 141,
      "reports": 6
    },
    "metrics": {
      "completion_percent": 93.1,
      "average_response_seconds": 11.2,
      "average_report_score": 7.9,
      "current_streak_days": 4
    },
    "weekly_comparison": {
      "current": {
        "sessions": 3,
        "average_score": 8.2,
        "completion_percent": 96.7
      },
      "previous": {
        "sessions": 2,
        "average_score": 7.6,
        "completion_percent": 90.0
      },
      "changes": {
        "average_score": 0.6,
        "completion_percentage_points": 6.7
      }
    },
    "trends": [
      {
        "session_id": "19df8fd0-13a7-4dbf-b919-79a21cb8da15",
        "date": "2026-10-02",
        "completion_percent": 100,
        "average_response_seconds": 11.8,
        "report_score": 8.2
      }
    ],
    "weak_areas": [
      {
        "code": "LOW_SPECIFICITY",
        "label": "Responses can be too general",
        "report_count": 4,
        "recent_direction": "improving",
        "recommended_drill": "ACTOR_ACTION_DRILL"
      }
    ],
    "generated_at": "2026-10-02T10:00:00Z"
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `VALIDATION_ERROR`,
`INTERNAL_ERROR`

**Business rules:**

- Date boundaries use the profile timezone; storage remains UTC.
- Trends use completed sessions. Score trends use ready reports only.
- Weak areas require at least two ready reports containing the same weakness.
- If insufficient data exists, arrays are empty and numeric report aggregates
  are `null`; the API does not invent a trend.
- Imported client timing may appear in activity totals but is excluded from
  server-verified simulation timing comparisons.

---

## 9. Payment and entitlement endpoints

Payments occur outside Qiyadat through the configured Pakistani payment method.
Qiyadat stores the submitted transaction reference and an administrative
decision; it does not charge a card or wallet in v1.

### 9.1 List active payment offers

#### `GET /payment-offers`

**Caller:** Public

**Response — `200 OK`**

```json
{
  "data": [
    {
      "code": "founding-30d",
      "name": "Founding 30-day access",
      "currency": "PKR",
      "amount_minor": 150000,
      "access_days": 30,
      "benefits": {
        "additional_20_word_sessions": true,
        "session_access": "during_entitlement",
        "reports_per_rolling_window": 3,
        "report_window_hours": 24,
        "saved_history_and_progress": true
      },
      "accepted_methods": ["easypaisa", "jazzcash", "bank_transfer"],
      "instructions": "Send the exact amount, then submit the transaction ID for verification."
    }
  ]
}
```

The amount shown is an example. Production amount is configured by an active
database offer and must not be hard-coded from this document.

**Errors:** `FEATURE_DISABLED`, `INTERNAL_ERROR`

**Business rules:**

- Only active, currently valid offers are returned.
- Each offer returns its exact price, currency, duration, and benefits so the
  client can explain what paid access unlocks before the free demo begins.
- Paid access permits additional 20-word sessions during the entitlement and
  the configured report allowance. It does not bypass AI consent, feature kill
  switches, rate limits, provider safety caps, or ownership checks.
- Payment recipient account details should be displayed from separately
  reviewed public configuration, not from secrets.

---

### 9.2 Submit payment transaction ID

#### `POST /payments`

**Caller:** Authenticated user  
**Header:** `Idempotency-Key` required

**Request**

```json
{
  "offer_code": "founding-30d",
  "payment_method": "easypaisa",
  "transaction_id": "EP-8392047712"
}
```

**Response — `201 Created`**

```json
{
  "data": {
    "id": "d57f2497-1458-43da-a1d6-23d437dd5113",
    "offer_code": "founding-30d",
    "payment_method": "easypaisa",
    "transaction_id_masked": "********7712",
    "status": "pending",
    "submitted_at": "2026-10-02T10:10:00Z",
    "decision": null
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `VALIDATION_ERROR`,
`PAYMENT_OFFER_INACTIVE`, `PAYMENT_PENDING_EXISTS`, `TRANSACTION_ID_EXISTS`,
`IDEMPOTENCY_CONFLICT`, `RATE_LIMITED`, `FEATURE_DISABLED`, `INTERNAL_ERROR`

**Business rules:**

- Normalize surrounding whitespace and provider-approved separators, but retain
  a protected encrypted/hashable representation for verification.
- `(payment_method, normalized_transaction_id)` is globally unique.
- A user may have only one pending submission at a time.
- Users cannot submit amount or access duration; those come from the offer.
- API responses and logs return only a masked transaction ID.
- Do not store WhatsApp chats or payment screenshots in v1.
- Submission does not grant access until an admin approves it.

---

### 9.3 List my payment submissions

#### `GET /payments?limit=20&cursor=<cursor>`

**Caller:** Authenticated user

**Response — `200 OK`**

```json
{
  "data": [
    {
      "id": "d57f2497-1458-43da-a1d6-23d437dd5113",
      "offer_code": "founding-30d",
      "payment_method": "easypaisa",
      "transaction_id_masked": "********7712",
      "status": "approved",
      "submitted_at": "2026-10-02T10:10:00Z",
      "decided_at": "2026-10-02T10:30:00Z",
      "rejection": null,
      "entitlement": {
        "type": "founding_30d",
        "starts_at": "2026-10-02T10:30:00Z",
        "expires_at": "2026-11-01T10:30:00Z"
      }
    }
  ],
  "meta": {
    "next_cursor": null,
    "has_more": false
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `VALIDATION_ERROR`,
`INTERNAL_ERROR`

---

### 9.4 Admin list payment submissions

#### `GET /admin/payments?status=pending&limit=50&cursor=<cursor>`

**Caller:** Admin

Optional filters: `status`, `payment_method`, `submitted_from`, `submitted_to`,
and exact `transaction_id` search.

**Response — `200 OK`**

```json
{
  "data": [
    {
      "id": "d57f2497-1458-43da-a1d6-23d437dd5113",
      "user": {
        "id": "ba27fbf1-0ce7-4f82-b9d2-e6c76b78f031",
        "email": "candidate@example.com",
        "display_name": "A. Khan"
      },
      "offer": {
        "code": "founding-30d",
        "currency": "PKR",
        "amount_minor": 150000,
        "access_days": 30
      },
      "payment_method": "easypaisa",
      "transaction_id": "EP-8392047712",
      "status": "pending",
      "submitted_at": "2026-10-02T10:10:00Z"
    }
  ],
  "meta": {
    "next_cursor": null,
    "has_more": false
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `ADMIN_REQUIRED`,
`VALIDATION_ERROR`, `INTERNAL_ERROR`

**Business rules:** Full transaction IDs are visible only in this admin
verification view and must not be copied into logs or audit notes.

---

### 9.5 Admin approve payment

#### `POST /admin/payments/{payment_id}/approve`

**Caller:** Admin

**Request**

```json
{
  "verification_note": "Matched against Easypaisa statement for 2026-10-02."
}
```

**Response — `200 OK`**

```json
{
  "data": {
    "payment_id": "d57f2497-1458-43da-a1d6-23d437dd5113",
    "status": "approved",
    "decided_at": "2026-10-02T10:30:00Z",
    "decided_by": "93d7f769-c101-4366-b417-4aac79ed138f",
    "entitlement": {
      "id": "8fbd69fc-d257-4e66-b30d-c438e79a5c9b",
      "type": "founding_30d",
      "starts_at": "2026-10-02T10:30:00Z",
      "expires_at": "2026-11-01T10:30:00Z",
      "status": "active"
    }
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `ADMIN_REQUIRED`, `NOT_FOUND`,
`PAYMENT_ALREADY_DECIDED`, `VALIDATION_ERROR`, `INTERNAL_ERROR`

**Business rules:**

- Approval and entitlement creation occur in one database transaction.
- If active paid access already exists, new access begins at the existing
  `expires_at` and adds 30 days; otherwise it begins at approval time.
- The offer captured when payment was submitted controls access duration.
- `verification_note` is admin-only, limited to 500 characters, and must not
  contain credentials, full chat transcripts, or unnecessary personal data.
- Insert an immutable `admin_audit_log` entry.

---

### 9.6 Admin reject payment

#### `POST /admin/payments/{payment_id}/reject`

**Caller:** Admin

**Request**

```json
{
  "reason_code": "TRANSACTION_NOT_FOUND",
  "message": "We could not match this transaction ID. Check the ID and submit again."
}
```

Allowed reason codes:

- `TRANSACTION_NOT_FOUND`
- `AMOUNT_MISMATCH`
- `DUPLICATE_TRANSACTION`
- `WRONG_RECIPIENT`
- `OTHER`

**Response — `200 OK`**

```json
{
  "data": {
    "payment_id": "d57f2497-1458-43da-a1d6-23d437dd5113",
    "status": "rejected",
    "decided_at": "2026-10-02T10:30:00Z",
    "rejection": {
      "reason_code": "TRANSACTION_NOT_FOUND",
      "message": "We could not match this transaction ID. Check the ID and submit again."
    }
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `ADMIN_REQUIRED`, `NOT_FOUND`,
`PAYMENT_ALREADY_DECIDED`, `VALIDATION_ERROR`, `INTERNAL_ERROR`

**Business rules:** Rejection grants no entitlement. After rejection, the user
may submit a different transaction ID. The rejected ID remains reserved and
cannot be reused by another account.

---

## 10. Privacy endpoints

### 10.1 Request my data export

#### `POST /privacy/export`

**Caller:** Authenticated user  
**Header:** `Idempotency-Key` required

**Request**

```json
{
  "format": "json_zip"
}
```

**Response — `202 Accepted`**

```json
{
  "data": {
    "export_id": "0425b1f0-deba-467a-9b54-6590dc207ede",
    "job_id": "8cb15707-9538-4a6d-aa05-28a21437b69f",
    "status": "queued",
    "poll_after_ms": 3000
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `DATA_EXPORT_IN_PROGRESS`,
`IDEMPOTENCY_CONFLICT`, `RATE_LIMITED`, `INTERNAL_ERROR`

**Business rules:**

- Export includes profile, consent history, entitlements, WAT sessions,
  responses, reports, progress-source data, and the user's payment submissions.
- Export excludes secrets, hidden prompts, provider raw payloads, admin-only
  verification notes, internal security logs, and other users' data.
- Only one active export per user is allowed.

---

### 10.2 Download completed export

#### `GET /privacy/exports/{export_id}`

**Caller:** Authenticated export owner

**Response — `200 OK`**

```json
{
  "data": {
    "id": "0425b1f0-deba-467a-9b54-6590dc207ede",
    "status": "ready",
    "format": "json_zip",
    "download_url": "https://<project-ref>.supabase.co/storage/v1/object/sign/exports/...",
    "download_url_expires_at": "2026-10-02T11:10:00Z",
    "file_expires_at": "2026-10-03T11:00:00Z"
  }
}
```

If still processing, return `200` with `status=queued|processing` and no URL.

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `NOT_FOUND`,
`PROVIDER_UNAVAILABLE`, `INTERNAL_ERROR`

**Business rules:** Download URLs last 10 minutes. Export files are private and
deleted after 24 hours.

---

### 10.3 Delete my account and data

#### `DELETE /privacy/me`

**Caller:** Authenticated user with authentication age of at most 10 minutes

**Request**

```json
{
  "confirmation": "DELETE MY ACCOUNT"
}
```

**Response — `202 Accepted`**

```json
{
  "data": {
    "status": "deletion_queued",
    "requested_at": "2026-10-02T11:00:00Z",
    "complete_by": "2026-10-03T11:00:00Z"
  }
}
```

**Errors:** `AUTH_REQUIRED`, `AUTH_INVALID`, `REAUTH_REQUIRED`,
`VALIDATION_ERROR`, `INTERNAL_ERROR`

**Business rules:**

- Account access is disabled immediately.
- Deletion removes Auth identity, profile, sessions, responses, reports,
  entitlements, usage reservations, exports, temporary images, and pending
  jobs.
- Payment rows may retain the minimum transaction and audit record legally or
  operationally required for fraud prevention and financial reconciliation;
  user-facing profile fields are removed or irreversibly pseudonymized.
- Admin audit records retain the action type and pseudonymous subject id, not
  deleted profile content.
- Auth identity is deleted last so cleanup can complete with a stable owner id.
- The frontend signs out and clears local Qiyadat storage after receiving `202`.

---

## 11. Database table reference

This is a reference list, not executable SQL. Migrations define exact types,
constraints, indexes, triggers, and RLS policies.

| Table | Purpose | Important rules |
|---|---|---|
| `profiles` | Candidate profile and preferences | PK/FK to `auth.users`; user reads/updates safe own fields |
| `profile_consents` | Versioned AI/privacy consent history | Append-only for users; no client deletion |
| `admin_users` | Explicit admin allowlist | Service-managed; never writable by normal users |
| `entitlements` | Beta, lifetime diagnostic-demo claim, and paid access windows | Server/admin write only; user reads own active/history rows |
| `payment_offers` | Price, currency, method, duration, validity | Public read through API; admin/service write |
| `payment_submissions` | External transaction verification workflow | User reads own; admin decision only; unique provider transaction id |
| `wat_sets` | Versioned diagnostic/practice set metadata | Published versions immutable |
| `wat_set_items` | Ordered words in each versioned set | Unique set/version/position and normalized word |
| `wat_sessions` | Canonical session and state machine | Owner-scoped; explicitly marks the single lifetime free demo; state changes only through functions/RPCs |
| `wat_responses` | One response per session position | Unique session/position; snapshots word text |
| `paper_uploads` | Temporary private image metadata | No public reads; deletion state tracked |
| `ocr_drafts` | Temporary mapped OCR text and confidence | Replaced by confirmed responses; raw provider payload not retained |
| `processing_jobs` | Durable OCR, feedback, export, cleanup jobs | Claimed with locking; bounded retries; safe errors |
| `feedback_reports` | Session-level final report | One final report per session/rubric version |
| `feedback_items` | Per-sentence ratings and feedback | One row per report/position |
| `usage_reservations` | Rolling report limits and provider counters | Transactional reservations prevent race-condition overuse |
| `legacy_imports` | Import idempotency and source tracking | Unique user/client session id |
| `data_exports` | Temporary privacy export metadata | Private file, signed URL, 24-hour retention |
| `deletion_requests` | Account deletion lifecycle | Immediate access revocation; completion tracking |
| `admin_audit_log` | Immutable privileged-action history | Append-only; no candidate answers or full transaction IDs |
| `app_settings` | Feature flags and global safety caps | Service/admin managed; safe subset exposed through API |
| `api_idempotency_keys` | Stored operation result hashes | Scoped to user and route; automatic expiry |

### 11.1 Required RLS posture

- Enable RLS on every application table in `public`.
- Normal users may select only their own candidate-facing records.
- Direct client insert/update/delete is denied for reports, jobs, entitlements,
  payments decisions, counters, settings, and audit logs.
- Sensitive mutations use authenticated Edge Functions and transaction-safe
  database functions.
- Service credentials are used only in isolated server clients and never mixed
  with a user's Authorization header.
- Storage policies restrict temporary paper objects to server-issued paths. The
  candidate receives upload permission, not list/read permission.

### 11.2 Required indexes and uniqueness

At minimum:

- Unique `wat_sessions(user_id, client_session_id)`.
- Partial unique `wat_sessions(user_id)` for rows marked as the account's free
  diagnostic demo. The marker is server-controlled and cannot be supplied or
  changed by the client.
- Unique `wat_responses(session_id, position)`.
- Unique `wat_set_items(wat_set_id, version, position)`.
- Unique final `feedback_reports(session_id, rubric_version)`.
- The free-demo session has at most one final `feedback_reports` row across all
  rubric versions; changing `rubric_version` cannot obtain a second free report.
- Unique normalized `payment_submissions(payment_method, transaction_id_hash)`.
- Partial unique pending payment per user.
- Job indexes on `(status, next_attempt_at, created_at)`.
- History index on `(user_id, finished_at DESC, id DESC)`.
- Usage index on `(user_id, reserved_at DESC)`.
- Expiry indexes for uploads, exports, sessions, and entitlements.

---

## 12. State transitions and background processing

### 12.1 Session states

```text
in_progress
  ├─ typed finish ───────────────> finished
  └─ paper finish ───────────────> awaiting_upload

awaiting_upload
  └─ OCR requested ──────────────> ocr_queued

ocr_queued
  └─ worker claim ───────────────> ocr_processing

ocr_processing
  ├─ success ────────────────────> awaiting_confirmation
  ├─ retryable failure ──────────> ocr_queued
  └─ terminal failure ───────────> failed

awaiting_confirmation
  └─ candidate confirms ─────────> finished

finished
  └─ report requested ───────────> feedback_queued

feedback_queued
  └─ worker claim ───────────────> feedback_processing

feedback_processing
  ├─ success ────────────────────> ready
  ├─ retryable failure ──────────> feedback_queued
  └─ terminal failure ───────────> failed
```

No client may set these states directly.

For the canonical free demo, a verified technical failure may be recovered only
on the same session. A trusted service returns it to the last safe state for the
failed operation, such as `ocr_queued` or `finished`; it never creates a second
free session, clears accepted answers, or changes the original word snapshots.

### 12.2 Durable job rules

- Enqueue and state transition occur in one database transaction.
- Workers claim jobs using row locking so only one worker processes a job.
- Every provider request has a timeout and stable request correlation id.
- Background Edge Function execution is best-effort acceleration; scheduled job
  processing is the recovery mechanism.
- Retry only transient failures. Validation failures, unsafe requests, invalid
  files, and exhausted controlled output retries are terminal.
- Exponential backoff is bounded. Jobs never retry forever.
- A provider success followed by database failure must be safe to replay without
  creating duplicate reports or counters.

---

## 13. Security and privacy requirements

### Required

- Store Supabase secret keys, Google service credentials, Gemini API key, and
  internal scheduler secret only in Supabase Edge Function secrets/Vault.
- Validate JWT and ownership again inside each protected function.
- Validate request schema before database or provider operations.
- Verify image magic bytes, checksum, size, count, and expected private path.
- Re-encode images client-side to remove EXIF; treat this as privacy assistance,
  not a substitute for server validation.
- Use generic ownership errors and constant-behavior authentication failures.
- Rate-limit auth-sensitive, upload, OCR, report, payment, export, and admin
  routes.
- Treat answers, OCR text, and transaction references as sensitive data.
- Require explicit current-version consent before sending text to Gemini.
- Delete confirmed paper images immediately and abandoned images within 24
  hours.
- Provide feature kill switches for OCR, feedback, payments, and beta access.

### Prohibited

- Never expose service-role, Google, Gemini, scheduler, or admin credentials in
  frontend JavaScript.
- Never authorize from `user_metadata`, a request role field, hidden UI button,
  or email address alone.
- Never trust client timestamps for strict simulation acceptance.
- Never silently accept OCR output as the candidate's response.
- Never send paper images, user identity, email, payment data, or exact account
  metadata to Gemini.
- Never log candidate response text, OCR text, report narrative, JWTs, signed
  URLs, full transaction IDs, or provider payloads.
- Never ask the model for diagnosis, personality classification, official ISSB
  judgment, or selection probability.
- Never issue reusable login passwords through WhatsApp.
- Never make production schema changes outside versioned migrations.

---

## 14. Testing and acceptance contract

An endpoint is not complete until its contract, authorization, error cases, and
business rules are covered.

### 14.1 API contract tests

- Validate every example against the request/response schema.
- Reject unknown enum values and incorrectly typed fields.
- Confirm all documented error codes use the shared error envelope.
- Verify idempotent replay and mismatched-body conflicts.
- Verify pagination order and cursor stability.

### 14.2 Authorization and RLS tests

- Anonymous, owner, other user, admin, and service contexts for every table.
- Cross-user session, report, payment, export, job, and image access returns
  `404` or RLS denial.
- A normal user cannot self-grant admin or entitlement access.
- Publishable frontend credentials cannot bypass RLS.

### 14.3 Session tests

- Training and simulation, typing and paper, natural and early finish.
- Early simulation answer, on-time answer, grace-window answer, and late answer.
- Duplicate answer, duplicate finish, expired session, and stale config.
- Blank, 280-character, 281-character, Unicode, and malformed responses.
- Guest import, legacy import, duplicate import, and untrusted timing labels.
- Exactly one lifetime free 20-word demo per account under concurrent starts,
  different idempotency keys, browsers, devices, and response modes.
- Resume returns the same unfinished demo with accepted answers unchanged;
  ordinary abandonment cannot create a replacement demo.
- Verified technical recovery reuses the same demo, while an untrusted client
  cannot mark its own failure as technical or reset the lifetime allowance.

### 14.4 OCR tests

- One to four pages, ordering, rotation, poor light, missing numbering, blank
  lines, duplicated lines, and low confidence.
- Unsupported format, spoofed MIME, oversized file, checksum mismatch, expired
  upload, and another user's upload id.
- Candidate correction, stale OCR revision, immediate deletion, delete retry,
  and 24-hour abandoned cleanup.

### 14.5 Feedback tests

- Structured schema validity, all-blank session, partial session, long answers,
  sensitive content, and prompt injection embedded in an answer.
- Provider timeout, refusal, malformed output, one controlled retry, terminal
  failure, and quota release.
- The free report belongs only to the canonical free demo; a terminal technical
  failure releases its reservation and retrying the same session succeeds
  without granting a second report or demo.
- A different rubric version, prompt version, or idempotency key cannot create a
  second final report for the free demo.
- The completed demo and final report remain readable after free use or paid
  expiry, while another user's records remain hidden.
- Score calculation is deterministic and excludes unscored blanks.
- Test corpus contains no diagnostic, official selection, or guaranteed-outcome
  language.

### 14.6 Payment tests

- Unique normalized transaction IDs, one pending submission, inactive offer,
  approve, reject, repeated decision, extension of active access, exact expiry,
  and admin audit creation.
- Non-admins cannot list or decide other users' payments.
- Candidate responses always contain masked transaction IDs.
- Public offers return price, currency, duration, and the exact benefits used by
  the required pre-demo disclosure; inactive or absent offers never produce a
  stale client price.

### 14.7 Privacy tests

- Export includes only the caller's candidate-facing data.
- Signed URL expiry and export-file cleanup.
- Recent-auth requirement for deletion.
- Account deletion clears database, Storage, jobs, and Auth identity in the
  documented order.

---

## 15. Out of scope for v1

- TAT, SRT, interview, lecturette, and initial-test modules.
- Native Android or iOS applications.
- Live proctoring, webcam monitoring, anti-cheat guarantees, or official exam
  delivery.
- Automated card, bank, Easypaisa, or JazzCash payment collection and webhooks.
- Storing WhatsApp conversations or payment screenshots.
- Permanent username/password credentials issued by an administrator.
- Social login, phone-number login, and organization/team accounts.
- Human psychologist or assessor marketplace.
- Psychological diagnosis, personality profiling, mental-health scoring,
  selection prediction, or official ISSB recommendations.
- Automatic acceptance of handwriting without candidate review.
- Urdu handwriting OCR or multilingual feedback.
- Offline cloud synchronization while unauthenticated; guest sessions remain
  local until the user signs in and imports them.
- Editing published WAT set versions; changes create a new immutable version.
- Re-generating multiple reports for the same session in v1.
- Public sharing of sessions or reports.
- Provider-specific raw OCR or AI payload access.

---

## 16. Implementation completion checklist

- [ ] OpenAPI/JSON schemas mirror this document.
- [ ] All database changes are versioned migrations.
- [ ] RLS is enabled and tested on every application table.
- [ ] Local, staging, and production use different credentials and projects.
- [ ] Supabase publishable key is the only backend key available to the browser.
- [ ] OCR and feedback provider adapters are replaceable.
- [ ] Job processor and cleanup schedules are deployed and observable.
- [ ] Images are private and deletion behavior is verified in production.
- [ ] Report and payment quotas are enforced transactionally.
- [ ] The lifetime free-demo claim is transactional, concurrency-safe, and
  linked to exactly one 20-word server session and one final report.
- [ ] The pre-demo screen renders live offer price and benefits from
  `GET /payment-offers` before the candidate confirms the demo.
- [ ] Admin actions produce immutable audit records.
- [ ] The privacy export and account deletion flows pass end-to-end tests.
- [ ] User-facing screens include the independent-practice disclaimer.
- [ ] Production launch begins with a limited beta and global kill switches.
