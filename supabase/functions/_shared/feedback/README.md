# Feedback pipeline

The API router handles POST/GET `/wat/sessions/{id}/report` and GET `/jobs/{id}`.
It never calls Gemini. The POST uses a service-only transaction with the
Auth-verified caller UUID. Report reads use the user client and RLS. Trusted
admins may read only safe job operational fields through the protected RPC.

`schema.ts` owns rubric v1 vocabulary and structured JSON schema. `prompt.ts`
projects input to position, word and answer only, quoting answers as JSON data.
`gemini.ts` sends the schema using the Developer API generateContent endpoint,
with a bounded timeout and response body. It requests no tools or reasoning.
`output.ts` validates every nested field, position, enum, length, rating,
blank, evidence position and prohibited guidance. The language detector is a
defense-in-depth guard, not a proof that every possible paraphrase is safe.
`scoring.ts` implements testable backend arithmetic and display labels.
PostgreSQL independently derives persisted scores from validated integer ratings.

`worker.ts` recovers stale leases and claims one due job per invocation. It
rechecks consent and feature flags before dispatch. It retries a completion
transaction once with the same validated output after a lost acknowledgement.
It stores neither raw provider output nor prompts. Errors use an allowlist.
`retry.ts` maps transient network/provider errors and invalid output to one
controlled retry; quota, consent and feature failures are terminal.

## Worker invocation

Serve all functions locally (omitting a function name):

```powershell
$qiyadatCli = Join-Path $env:USERPROFILE 'node_modules\supabase\dist\supabase.js'
node $qiyadatCli functions serve --no-verify-jwt --env-file <untracked-env-path>
```

The worker URL is `http://127.0.0.1:55321/functions/v1/feedback-worker`.
Send POST with JSON `{}` and `Authorization: Bearer <worker-secret>`.
`QIYADAT_WORKER_SECRET` must contain at least 32 characters. Publishable keys
and candidate JWTs cannot invoke processing. No caller may choose a job, user,
state or clock. A trusted scheduler should invoke this endpoint periodically;
each call drains one due job and recovers up to 20 stale leases. Scheduling
deployment is intentionally absent from this local-only phase. Jobs remain
durable while no runner is active and resume on the next trusted invocation.

For unattended local processing, run `npm run worker:feedback` in another
terminal with the same private QIYADAT_WORKER_SECRET in its environment. It
invokes only the fixed loopback worker URL every five seconds and stops with
Ctrl+C. No provider key is needed in the polling process.

Required worker environment names: GEMINI_API_KEY, GEMINI_MODEL,
GEMINI_PROMPT_VERSION, GEMINI_REQUEST_TIMEOUT_MS, QIYADAT_WORKER_SECRET plus
the automatically injected Supabase environment. Timeout defaults to 60000 ms
and is capped at 120000 ms. Missing credentials disable the worker safely.
Provider/model/prompt versions are preserved with the report; the first claim
snapshots model and prompt for subsequent retries.

The five-minute lease exceeds the provider timeout. Claims lock profile,
session, job and reservation in that order. Fresh worker UUIDs fence stale
results. Retry delays are 5 then 10 seconds, bounded at 60. Maximum attempts
is two. Failure atomically releases quota and marks trusted technical recovery
on the same session; it cannot grant another demo.

## Local tests

```powershell
npm run test:feedback:unit
npm run test:feedback:worker
npm run test:feedback:http
```

The HTTP runner starts a mock HTTP server, writes synthetic-only worker settings
to the OS temporary directory, starts the installed Edge Runtime, executes the
real HTTP suite, removes fixtures, closes the processes and removes the temp
file. It refuses hosted Supabase URLs. QIYADAT_LOCAL_TESTS and
QIYADAT_GEMINI_TEST_URL are test-only overrides, accepted solely for a local
Supabase gateway and a loopback/host.docker.internal HTTP mock. They do not
permit an arbitrary provider URL in hosted environments. No test needs a real
Gemini key. Run the HTTP suites serially because they share the local stack.
The Windows test harness uses the already installed native CLI executable to
avoid intermittent npm-launcher cold-start stalls. It does not install or
download a CLI. Fixture cleanup removes report items/reports before deleting
synthetic Auth accounts, respecting the existing response foreign key.

An optional real-provider smoke test is manual: supply a private untracked env
file, explicitly enable feedback only in the local database, accept current
consent with a synthetic account, finish a typed session, request a report,
invoke the worker, and poll/fetch the report. Restore local feature flags after
testing. The automated runner always overrides provider configuration with
synthetic values. Do not put real answers in a real-provider smoke test.

The free Gemini tier may use prompts/output to improve Google products. That
processing requires the existing current-version AI-processing disclosure.
No provider call may be made after withdrawal; stored reports remain readable.
OCR and paper confirmation are deferred to Phase 4.
