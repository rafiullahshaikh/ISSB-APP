# Phase 3 contract decisions

The unchanged API_SPEC.md v1.1.0 is binding. These decisions fill unspecified
implementation details, without adding candidate endpoints or fields.

- Section 7.1 specializes generic exact replay: an existing report request
  returns its current job state; after success its original idempotency key
  returns HTTP 200 with `{data:{report_id,session_id,status:"ready"}}`. A new key
  after success returns REPORT_ALREADY_EXISTS. A failed job with the old key
  remains the same failed job; retrying the same session requires a new key.
- All-blank typed sessions contain canonical response rows and may produce a
  report with all entries not_scored, null aggregates and no invented evidence.
  Paper is rejected with SESSION_STATE_CONFLICT until Phase 4 confirmation.
- Rubric v1 labels, summary codes, bounded text and drill enums are versioned in
  the structured schema. The specification provides examples, not a complete
  enum vocabulary. Ratings are 1-5; dimension scores are mean rating times two;
  overall is the mean of unrounded sentence scores, rounded once to one decimal.
- A new migration extends the session guard only for failed feedback jobs with
  trusted technical_failure_verified_at and released reservations. This permits
  recovery of the same session to finished, never a replacement free demo.
- Processing leases last five minutes, exceeding the maximum provider timeout
  of two minutes. Each claim has a fresh worker UUID, preventing stale workers
  from completing or failing a later attempt. Retry delay is 5 * 2^(attempt-1)
  seconds, capped at 60; at most two provider attempts per job.
- A server-only daily provider-attempt cap defaults to 100. This operational
  safety setting is not a user entitlement or public configuration constant.
  Enqueue checks it and claim atomically increments it before provider calls.
- Consent and kill switches are rechecked at claim and immediately before
  provider dispatch. Previously generated reports remain readable regardless
  of current consent, feature flags or entitlement.
- The normal automated suite uses a local HTTP Gemini mock and in-memory fake
  providers. No automated test requires a real key or contacts Google.

Model verification (2026-10-16): Google's official model page lists
gemini-3.5-flash-lite as a stable Developer API model supporting text and
structured outputs; the pricing page lists free input/output. Free-tier data
may be used to improve Google's products; the current explicit AI-processing
consent is required. GEMINI_MODEL remains mandatory and configurable, with no
fallback substitution.

Sources: https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite,
https://ai.google.dev/gemini-api/docs/pricing,
https://ai.google.dev/gemini-api/docs/structured-output.
