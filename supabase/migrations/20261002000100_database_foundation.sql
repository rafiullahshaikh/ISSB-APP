-- API_SPEC.md v1.0.0 is the binding contract. No endpoint is implemented here.
begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;
create extension if not exists pgcrypto with schema extensions;

create type public.account_role as enum ('candidate');
create type public.wat_kind as enum ('diagnostic', 'practice');
create type public.practice_mode as enum ('training', 'simulation');
create type public.response_mode as enum ('typing', 'paper');
create type public.session_source as enum ('server', 'guest_local', 'legacy_local_storage');
create type public.timing_trust as enum ('server_verified', 'client_reported');
create type public.session_status as enum (
  'in_progress', 'finished', 'awaiting_upload', 'ocr_queued', 'ocr_processing',
  'awaiting_confirmation', 'feedback_queued', 'feedback_processing', 'ready', 'failed'
);
create type public.response_source as enum ('typed', 'ocr_confirmed', 'legacy_typed');
create type public.response_status as enum ('answered', 'blank', 'not_attempted');
create type public.advance_reason as enum ('timer', 'next', 'session_end', 'autosave');
create type public.finish_reason as enum ('natural', 'manual');
create type public.entitlement_type as enum ('beta', 'diagnostic', 'founding_30d');
create type public.entitlement_status as enum ('active', 'expired', 'revoked');
create type public.payment_method as enum ('easypaisa', 'jazzcash', 'bank_transfer');
create type public.payment_status as enum ('pending', 'approved', 'rejected');
create type public.payment_rejection_code as enum (
  'TRANSACTION_NOT_FOUND', 'AMOUNT_MISMATCH', 'DUPLICATE_TRANSACTION', 'WRONG_RECIPIENT', 'OTHER'
);
create type public.job_type as enum ('ocr', 'feedback', 'export', 'cleanup');
create type public.job_status as enum ('queued', 'processing', 'retrying', 'succeeded', 'failed');
create type public.upload_status as enum ('prepared', 'uploaded', 'delete_pending', 'deleted');
create type public.feedback_status as enum ('scored', 'not_scored');
create type public.safety_flag as enum ('self_harm', 'violence', 'other_sensitive');
create type public.usage_type as enum ('report', 'diagnostic_report', 'ocr_page');
create type public.reservation_status as enum ('reserved', 'consumed', 'released');
create type public.export_status as enum ('queued', 'processing', 'ready', 'failed', 'expired');
create type public.deletion_status as enum ('deletion_queued', 'processing', 'completed', 'failed');
create type public.audit_action as enum (
  'payment_approved', 'payment_rejected', 'entitlement_granted', 'entitlement_revoked',
  'settings_changed', 'admin_added', 'admin_removed'
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (display_name is null or
    (display_name = btrim(display_name) and char_length(display_name) between 1 and 80)),
  timezone text not null default 'Asia/Karachi',
  -- This is a candidate default, never an admin authorization source.
  role public.account_role not null default 'candidate',
  access_disabled_at timestamptz check (access_disabled_at is null or isfinite(access_disabled_at)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profile_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  terms_version text not null check (char_length(terms_version) between 1 and 80),
  accepted boolean not null,
  accepted_at timestamptz not null default now() check (isfinite(accepted_at)),
  created_at timestamptz not null default now()
);

create table public.admin_users (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  active boolean not null default true,
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payment_offers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (char_length(code) between 1 and 80),
  name text not null check (char_length(name) between 1 and 160),
  currency text not null default 'PKR' check (currency = 'PKR'),
  amount_minor bigint not null check (amount_minor > 0),
  access_days integer not null default 30 check (access_days = 30),
  accepted_methods public.payment_method[] not null check (cardinality(accepted_methods) between 1 and 3
    and array_position(accepted_methods, null) is null),
  instructions text not null check (char_length(instructions) <= 2000),
  active boolean not null default false,
  valid_from timestamptz not null default now() check (isfinite(valid_from)),
  valid_until timestamptz check (valid_until is null or (isfinite(valid_until) and valid_until > valid_from)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payment_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  offer_id uuid not null references public.payment_offers(id),
  offer_code text not null,
  currency text not null check (currency = 'PKR'),
  amount_minor bigint not null check (amount_minor > 0),
  access_days integer not null check (access_days = 30),
  payment_method public.payment_method not null,
  -- Future server encrypts the normalized reference before persistence. No raw reference column.
  transaction_id_ciphertext bytea not null check (octet_length(transaction_id_ciphertext) > 0),
  transaction_id_hash text not null check (transaction_id_hash ~ '^[0-9a-f]{64}$'),
  transaction_id_masked text not null check (transaction_id_masked ~ '^\*{4,}.{1,4}$'),
  status public.payment_status not null default 'pending',
  verification_note text check (char_length(verification_note) <= 500),
  rejection_reason_code public.payment_rejection_code,
  rejection_message text check (char_length(rejection_message) between 1 and 500),
  submitted_at timestamptz not null default now() check (isfinite(submitted_at)),
  decided_at timestamptz check (decided_at is null or (isfinite(decided_at) and decided_at >= submitted_at)),
  -- Pseudonymous decision actor survives admin account erasure; validated by a trigger.
  decided_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (payment_method, transaction_id_hash),
  check (
    (status = 'pending' and decided_at is null and decided_by is null
      and rejection_reason_code is null and rejection_message is null and verification_note is null)
    or (status = 'approved' and decided_at is not null and decided_by is not null
      and rejection_reason_code is null and rejection_message is null)
    or (status = 'rejected' and decided_at is not null and decided_by is not null
      and rejection_reason_code is not null and rejection_message is not null)
  )
);
create unique index payment_one_pending_per_user on public.payment_submissions(user_id) where status = 'pending';

create table public.entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type public.entitlement_type not null,
  status public.entitlement_status not null default 'active',
  starts_at timestamptz not null default now() check (isfinite(starts_at)),
  expires_at timestamptz check (expires_at is null or isfinite(expires_at)),
  payment_submission_id uuid unique references public.payment_submissions(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at is null or expires_at > starts_at),
  check (type <> 'founding_30d' or
    (expires_at is not null and expires_at = starts_at + interval '30 days'))
);

create table public.wat_sets (
  id uuid primary key default gen_random_uuid(),
  code text not null check (char_length(code) between 1 and 80),
  version integer not null check (version > 0),
  kind public.wat_kind not null,
  schema_version integer not null default 1 check (schema_version = 1),
  total_words integer not null default 20 check (total_words = 20),
  seconds_per_word integer not null default 15 check (seconds_per_word = 15),
  answer_grace_ms integer not null default 2000 check (answer_grace_ms = 2000),
  answer_max_chars integer not null default 280 check (answer_max_chars = 280),
  published_at timestamptz check (published_at is null or isfinite(published_at)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (code, version), unique (id, version), unique (id, version, kind)
);

create table public.wat_set_items (
  id uuid primary key default gen_random_uuid(),
  wat_set_id uuid not null,
  version integer not null,
  position integer not null check (position between 1 and 20),
  word text not null check (word = btrim(word) and char_length(word) between 1 and 80),
  normalized_word text generated always as (lower(normalize(btrim(word), NFC))) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (wat_set_id, version) references public.wat_sets(id, version) on delete cascade,
  unique (wat_set_id, version, position), unique (wat_set_id, version, normalized_word)
);

create table public.wat_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  client_session_id text not null check (char_length(client_session_id) between 1 and 128),
  wat_set_id uuid not null,
  set_version integer not null,
  schema_version integer not null default 1 check (schema_version = 1),
  kind public.wat_kind not null,
  practice_mode public.practice_mode not null,
  response_mode public.response_mode not null,
  status public.session_status not null default 'in_progress',
  source public.session_source not null default 'server',
  timing_trust public.timing_trust not null default 'server_verified',
  session_size integer not null default 20 check (session_size = 20),
  seconds_per_word integer not null default 15 check (seconds_per_word = 15),
  answer_grace_ms integer not null default 2000 check (answer_grace_ms = 2000),
  answer_max_chars integer not null default 280 check (answer_max_chars = 280),
  started_at timestamptz not null default now() check (isfinite(started_at)),
  expires_at timestamptz not null default (now() + interval '30 minutes') check (isfinite(expires_at)),
  finished_at timestamptz check (finished_at is null or isfinite(finished_at)),
  finish_reason public.finish_reason,
  ended_early boolean not null default false,
  eligible_for_feedback boolean not null default true,
  imported_at timestamptz check (imported_at is null or isfinite(imported_at)),
  ocr_revision integer not null default 0 check (ocr_revision >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (wat_set_id, set_version, kind) references public.wat_sets(id, version, kind),
  unique (user_id, client_session_id), unique (id, user_id), unique (id, user_id, client_session_id),
  check (expires_at = started_at + interval '30 minutes'),
  check (finished_at is null or finished_at >= started_at),
  check ((status = 'in_progress' and finished_at is null) or (status <> 'in_progress' and finished_at is not null)),
  check (response_mode = 'paper' or status not in
    ('awaiting_upload', 'ocr_queued', 'ocr_processing', 'awaiting_confirmation')),
  check ((source = 'server' and timing_trust = 'server_verified' and imported_at is null)
    or (source <> 'server' and timing_trust = 'client_reported' and imported_at is not null))
);
create unique index session_one_in_progress_per_user on public.wat_sessions(user_id) where status = 'in_progress';

create table public.wat_responses (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null,
  user_id uuid not null,
  position integer not null check (position between 1 and 20),
  word text not null check (char_length(word) between 1 and 80),
  answer text not null default '' check (char_length(answer) <= 280),
  source public.response_source not null,
  status public.response_status not null default 'not_attempted',
  completed boolean not null default false,
  locked boolean not null default false,
  time_used_ms integer check (time_used_ms >= 0),
  client_elapsed_ms integer check (client_elapsed_ms >= 0),
  client_saved_at timestamptz check (client_saved_at is null or isfinite(client_saved_at)),
  advance_reason public.advance_reason,
  received_at timestamptz check (received_at is null or isfinite(received_at)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (session_id, user_id) references public.wat_sessions(id, user_id) on delete cascade,
  unique (session_id, position),
  check ((status = 'answered' and char_length(btrim(answer)) > 0 and completed)
    or (status = 'blank' and answer = '' and completed)
    or (status = 'not_attempted' and answer = '' and not completed))
);

create table public.paper_uploads (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null,
  user_id uuid not null,
  page_number integer not null check (page_number between 1 and 4),
  bucket_id text not null default 'paper-uploads' check (bucket_id = 'paper-uploads'),
  content_type text not null check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  size_bytes bigint not null check (size_bytes between 1 and 8388608),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  object_path text not null unique,
  status public.upload_status not null default 'prepared',
  upload_expires_at timestamptz not null default (now() + interval '15 minutes'),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  uploaded_at timestamptz,
  confirmed_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (session_id, user_id) references public.wat_sessions(id, user_id) on delete cascade,
  unique (session_id, page_number),
  check (object_path = user_id::text || '/' || session_id::text || '/' || id::text ||
    case content_type when 'image/jpeg' then '.jpg' when 'image/png' then '.png' else '.webp' end),
  check (isfinite(upload_expires_at) and upload_expires_at > created_at
    and upload_expires_at <= created_at + interval '900 seconds'),
  check (isfinite(expires_at) and expires_at > upload_expires_at
    and expires_at <= created_at + interval '24 hours'),
  check (uploaded_at is null or (isfinite(uploaded_at) and uploaded_at >= created_at)),
  check (confirmed_at is null or (uploaded_at is not null and isfinite(confirmed_at) and confirmed_at >= uploaded_at)),
  check ((status = 'deleted' and deleted_at is not null and isfinite(deleted_at) and deleted_at >= created_at)
    or (status <> 'deleted' and deleted_at is null)),
  check (status <> 'uploaded' or uploaded_at is not null)
);

create table public.ocr_drafts (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null,
  user_id uuid not null,
  ocr_revision integer not null check (ocr_revision > 0),
  position integer not null check (position between 1 and 20),
  ocr_text text not null default '' check (char_length(ocr_text) <= 10000),
  confidence numeric(5,4) check (confidence between 0 and 1),
  needs_review boolean not null default true,
  expires_at timestamptz not null default (now() + interval '24 hours') check (isfinite(expires_at) and expires_at > created_at),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (session_id, user_id) references public.wat_sessions(id, user_id) on delete cascade,
  unique (session_id, ocr_revision, position)
);

create table public.processing_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  session_id uuid,
  type public.job_type not null,
  status public.job_status not null default 'queued',
  attempt integer not null default 0 check (attempt >= 0),
  max_attempts integer not null check (max_attempts between 1 and 3),
  next_attempt_at timestamptz not null default now() check (isfinite(next_attempt_at)),
  started_at timestamptz,
  completed_at timestamptz,
  locked_at timestamptz,
  locked_by uuid,
  request_id uuid not null default gen_random_uuid(),
  -- Only IDs and safe operational codes; no arbitrary provider-payload field.
  error_code text check (error_code in ('OCR_FAILED', 'AI_OUTPUT_INVALID', 'PROVIDER_UNAVAILABLE',
    'VALIDATION_ERROR', 'UPLOAD_EXPIRED', 'UNSUPPORTED_MEDIA_TYPE', 'GLOBAL_QUOTA_EXHAUSTED', 'INTERNAL_ERROR')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (session_id, user_id) references public.wat_sessions(id, user_id) on delete cascade,
  unique (id, user_id), unique (id, user_id, session_id),
  check (attempt <= max_attempts),
  check ((type = 'ocr' and max_attempts <= 3) or (type = 'feedback' and max_attempts <= 2)
    or type in ('export', 'cleanup')),
  check (type not in ('ocr', 'feedback') or session_id is not null),
  check (started_at is null or (isfinite(started_at) and started_at >= created_at)),
  check (completed_at is null or (isfinite(completed_at) and completed_at >= created_at
    and (started_at is null or completed_at >= started_at))),
  check (locked_at is null or isfinite(locked_at)),
  check ((status = 'processing' and locked_at is not null and locked_by is not null and started_at is not null)
    or (status <> 'processing' and locked_at is null and locked_by is null)),
  check ((status in ('succeeded', 'failed') and completed_at is not null)
    or (status not in ('succeeded', 'failed') and completed_at is null))
);
create unique index jobs_one_active_per_session_type on public.processing_jobs(session_id, type)
  where status in ('queued', 'processing', 'retrying');

create table public.feedback_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  session_id uuid not null,
  job_id uuid not null,
  status text not null default 'ready' check (status = 'ready'),
  rubric_version text not null check (rubric_version = 'wat-rubric-v1'),
  prompt_version text not null check (char_length(prompt_version) between 1 and 80),
  model_provider text not null check (model_provider = 'google_gemini'),
  model_name text not null check (char_length(model_name) between 1 and 120),
  overall_score numeric(3,1) check (overall_score between 0 and 10),
  tone_score numeric(3,1) check (tone_score between 0 and 10),
  agency_score numeric(3,1) check (agency_score between 0 and 10),
  clarity_score numeric(3,1) check (clarity_score between 0 and 10),
  realism_score numeric(3,1) check (realism_score between 0 and 10),
  narrative text not null check (char_length(narrative) <= 4000),
  summary jsonb not null default '{}'::jsonb check (jsonb_typeof(summary) = 'object'),
  generated_at timestamptz not null default now() check (isfinite(generated_at)),
  created_at timestamptz not null default now(),
  foreign key (session_id, user_id) references public.wat_sessions(id, user_id) on delete cascade,
  foreign key (job_id, user_id, session_id) references public.processing_jobs(id, user_id, session_id),
  unique (session_id, rubric_version), unique (id, user_id, session_id)
);

create table public.feedback_items (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null,
  user_id uuid not null,
  session_id uuid not null,
  position integer not null check (position between 1 and 20),
  status public.feedback_status not null,
  tone_rating integer check (tone_rating between 1 and 5),
  agency_rating integer check (agency_rating between 1 and 5),
  clarity_rating integer check (clarity_rating between 1 and 5),
  realism_rating integer check (realism_rating between 1 and 5),
  score numeric(3,1) generated always as
    (round((tone_rating + agency_rating + clarity_rating + realism_rating)::numeric / 2, 1)) stored,
  strength text check (char_length(strength) <= 1000),
  feedback text not null check (char_length(feedback) <= 2000),
  -- Labels/notes are validated against the future structured rubric schema by the server.
  rating_notes jsonb check (rating_notes is null or jsonb_typeof(rating_notes) = 'object'),
  safety_flags public.safety_flag[] not null default '{}' check (array_position(safety_flags, null) is null),
  created_at timestamptz not null default now(),
  foreign key (report_id, user_id, session_id) references public.feedback_reports(id, user_id, session_id) on delete cascade,
  foreign key (session_id, position) references public.wat_responses(session_id, position),
  unique (report_id, position),
  check ((status = 'scored' and tone_rating is not null and agency_rating is not null
    and clarity_rating is not null and realism_rating is not null)
    or (status = 'not_scored' and tone_rating is null and agency_rating is null
      and clarity_rating is null and realism_rating is null and strength is null and rating_notes is null))
);

create table public.usage_reservations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  session_id uuid not null,
  job_id uuid not null,
  type public.usage_type not null,
  status public.reservation_status not null default 'reserved',
  -- Stable request key prevents recounting a replayed provider page request.
  operation_key text not null check (char_length(operation_key) between 1 and 128),
  amount integer not null default 1 check (amount = 1),
  reserved_at timestamptz not null default now() check (isfinite(reserved_at)),
  consumed_at timestamptz,
  released_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (session_id, user_id) references public.wat_sessions(id, user_id) on delete cascade,
  foreign key (job_id, user_id, session_id) references public.processing_jobs(id, user_id, session_id) on delete cascade,
  unique (type, operation_key),
  check ((status = 'reserved' and consumed_at is null and released_at is null)
    or (status = 'consumed' and consumed_at is not null and isfinite(consumed_at)
      and consumed_at >= reserved_at and released_at is null)
    or (status = 'released' and released_at is not null and isfinite(released_at)
      and released_at >= reserved_at and consumed_at is null))
);
create unique index usage_one_report_reservation_per_session on public.usage_reservations(session_id)
  where type in ('report', 'diagnostic_report') and status in ('reserved', 'consumed');
create unique index usage_one_lifetime_diagnostic on public.usage_reservations(user_id)
  where type = 'diagnostic_report' and status in ('reserved', 'consumed');

create table public.legacy_imports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  session_id uuid not null unique,
  client_session_id text not null check (char_length(client_session_id) between 1 and 128),
  source public.session_source not null check (source in ('guest_local', 'legacy_local_storage')),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  imported_at timestamptz not null default now() check (isfinite(imported_at)),
  created_at timestamptz not null default now(),
  foreign key (session_id, user_id, client_session_id)
    references public.wat_sessions(id, user_id, client_session_id) on delete cascade,
  unique (user_id, client_session_id)
);

create table public.data_exports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid not null unique,
  status public.export_status not null default 'queued',
  format text not null default 'json_zip' check (format = 'json_zip'),
  object_path text unique,
  ready_at timestamptz,
  file_expires_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (job_id, user_id) references public.processing_jobs(id, user_id) on delete cascade,
  check (object_path is null or object_path = user_id::text || '/' || id::text || '.zip'),
  check (ready_at is null or (isfinite(ready_at) and ready_at >= created_at)),
  check (file_expires_at is null or (isfinite(file_expires_at) and ready_at is not null
    and file_expires_at > ready_at and file_expires_at <= ready_at + interval '24 hours')),
  check (status <> 'ready' or (object_path is not null and ready_at is not null and file_expires_at is not null)),
  check (deleted_at is null or (isfinite(deleted_at) and deleted_at >= created_at))
);
create unique index exports_one_active_per_user on public.data_exports(user_id) where status in ('queued', 'processing');

create table public.deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references public.profiles(id) on delete set null,
  subject_id uuid not null, -- Pseudonymous lifecycle identity retained after Auth deletion.
  status public.deletion_status not null default 'deletion_queued',
  requested_at timestamptz not null default now() check (isfinite(requested_at)),
  complete_by timestamptz not null default (now() + interval '24 hours'),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (isfinite(complete_by) and complete_by > requested_at and complete_by <= requested_at + interval '24 hours'),
  check ((status = 'completed' and completed_at is not null and isfinite(completed_at) and completed_at >= requested_at)
    or (status <> 'completed' and completed_at is null))
);

create table public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null, -- No FK: audit survives account erasure.
  subject_id uuid,
  action public.audit_action not null,
  resource_id uuid,
  reason_code public.payment_rejection_code,
  request_id uuid not null,
  created_at timestamptz not null default now()
  -- Deliberately no free-form note, answers, payment references, or provider payloads.
);

create table public.app_settings (
  key text primary key check (char_length(key) between 1 and 100),
  value jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.api_idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  route text not null check (char_length(route) between 1 and 200),
  idempotency_key text not null check (char_length(idempotency_key) between 16 and 128
    and idempotency_key collate "C" ~ '^[ -~]+$'),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response_status integer check (response_status between 200 and 299),
  resource_id uuid,
  -- Store resource references, not sensitive response bodies or signed URLs.
  expires_at timestamptz not null default (now() + interval '24 hours'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, route, idempotency_key),
  check (isfinite(expires_at) and expires_at >= created_at + interval '24 hours')
);

create index profile_consents_history_idx on public.profile_consents(user_id, accepted_at desc, id desc);
create index entitlements_owner_idx on public.entitlements(user_id, starts_at desc, id desc);
create index entitlements_expiry_idx on public.entitlements(expires_at) where status = 'active';
create index payment_offers_validity_idx on public.payment_offers(active, valid_from, valid_until);
create index payments_history_idx on public.payment_submissions(user_id, created_at desc, id desc);
create index payments_review_idx on public.payment_submissions(status, payment_method, submitted_at desc, id desc);
create index payments_offer_idx on public.payment_submissions(offer_id);
create index payments_decider_idx on public.payment_submissions(decided_by);
create index sessions_history_idx on public.wat_sessions(user_id, finished_at desc, id desc);
create index sessions_expiry_idx on public.wat_sessions(expires_at) where status = 'in_progress';
create index sessions_set_idx on public.wat_sessions(wat_set_id, set_version);
create index responses_owner_idx on public.wat_responses(user_id, session_id);
create index uploads_expiry_idx on public.paper_uploads(expires_at) where status <> 'deleted';
create index uploads_authorization_expiry_idx on public.paper_uploads(upload_expires_at) where status = 'prepared';
create index uploads_owner_idx on public.paper_uploads(user_id, session_id);
create index ocr_drafts_owner_idx on public.ocr_drafts(user_id, session_id);
create index ocr_drafts_expiry_idx on public.ocr_drafts(expires_at);
create index jobs_processing_idx on public.processing_jobs(status, next_attempt_at, created_at);
create index jobs_recovery_idx on public.processing_jobs(locked_at) where status = 'processing';
create index jobs_owner_idx on public.processing_jobs(user_id, created_at desc, id desc);
create index jobs_session_idx on public.processing_jobs(session_id, user_id);
create index reports_owner_idx on public.feedback_reports(user_id, created_at desc, id desc);
create index reports_job_idx on public.feedback_reports(job_id);
create index feedback_items_owner_idx on public.feedback_items(user_id, report_id);
create index feedback_items_response_idx on public.feedback_items(session_id, position);
create index usage_owner_idx on public.usage_reservations(user_id, reserved_at desc);
create index usage_provider_window_idx on public.usage_reservations(type, reserved_at desc) where type = 'ocr_page';
create index usage_job_idx on public.usage_reservations(job_id);
create index imports_owner_idx on public.legacy_imports(user_id, created_at desc, id desc);
create index exports_expiry_idx on public.data_exports(file_expires_at) where deleted_at is null;
create index exports_owner_idx on public.data_exports(user_id, created_at desc, id desc);
create index deletion_pending_idx on public.deletion_requests(status, complete_by);
create index audit_actor_idx on public.admin_audit_log(actor_id, created_at desc, id desc);
create index audit_subject_idx on public.admin_audit_log(subject_id, created_at desc, id desc);
create index idempotency_expiry_idx on public.api_idempotency_keys(expires_at);

commit;
