-- Entire suite rolls back. UUIDs, accounts, references and ciphertext are synthetic.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

create function pg_temp.sqlstate(statement text) returns text
language plpgsql security invoker as $$
begin
  execute statement;
  return '00000';
exception when others then return sqlstate;
end;
$$;
grant execute on function pg_temp.sqlstate(text) to anon, authenticated, service_role;

create function pg_temp.failure_constraint(statement text) returns text
language plpgsql security invoker as $$
declare failed_constraint text;
begin
  execute statement;
  return 'NO_ERROR';
exception when others then
  get stacked diagnostics failed_constraint = constraint_name;
  return failed_constraint;
end;
$$;
grant execute on function pg_temp.failure_constraint(text) to anon, authenticated, service_role;

create temp table fixtures (
  user_id uuid, session_id uuid, paper_session_id uuid, job_id uuid,
  report_id uuid, export_job_id uuid, export_id uuid, upload_id uuid
);
insert into fixtures values
 ('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002',
  '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002',
  '60000000-0000-0000-0000-000000000002', '80000000-0000-0000-0000-000000000002');
grant select on fixtures to authenticated, service_role;

insert into auth.users(id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-000000000001', 'a@example.invalid', '{"role":"admin","is_admin":true}'),
 ('00000000-0000-0000-0000-000000000002', 'b@example.invalid', '{}'),
 ('00000000-0000-0000-0000-000000000003', 'admin@example.invalid', '{}'),
 ('00000000-0000-0000-0000-000000000004', 'deletion@example.invalid', '{}');

select is((select count(*)::integer from profiles), 4, 'Auth creates all four candidate profiles');
select is((select role::text from profiles where id = '00000000-0000-0000-0000-000000000001'),
 'candidate', 'Editable Auth admin metadata is ignored');
select is((select count(*)::integer from admin_users), 0, 'Auth never auto-grants admin membership');
select is((select count(*)::integer from payment_offers), 0, 'Seed contains no payment offer');
select is((select count(*)::integer from wat_set_items), 20, 'Seed contains exactly 20 words');
select is((select total_words || '/' || seconds_per_word || '/' || answer_grace_ms || '/' || answer_max_chars
 from wat_sets where code = 'diagnostic-v1'), '20/15/2000/280', 'Seed WAT rules match the contract');
select ok((select bool_and(value = 'false'::jsonb) from app_settings
 where key in ('beta_open', 'ocr_enabled', 'feedback_enabled', 'payments_enabled')), 'Feature flags fail closed');
select is((select value::text from app_settings where key = 'OCR_MONTHLY_APP_CAP'), '900', 'OCR safety cap is 900');

insert into admin_users(user_id) values ('00000000-0000-0000-0000-000000000003');
insert into profile_consents(user_id, terms_version, accepted)
select user_id, '2026-10-01', true from fixtures;
insert into entitlements(user_id, type) select user_id, 'beta' from fixtures;
insert into wat_sessions(id, user_id, client_session_id, wat_set_id, set_version, kind,
 practice_mode, response_mode, status, source, timing_trust, finished_at, imported_at)
select session_id, user_id, 'guest-fixture', '7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1', 1,
 'diagnostic', 'training', 'typing', 'finished', 'guest_local', 'client_reported', now(), now() from fixtures;
insert into wat_sessions(id, user_id, client_session_id, wat_set_id, set_version, kind, practice_mode, response_mode)
select paper_session_id, user_id, 'paper-fixture', '7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1', 1,
 'diagnostic', 'simulation', 'paper' from fixtures;
update wat_sessions set status = 'awaiting_upload', finished_at = now() where response_mode = 'paper';
insert into wat_responses(session_id, user_id, position, word, answer, source, status, completed)
select f.session_id, f.user_id, i.position, i.word, 'Synthetic practice answer.', 'typed', 'answered', true
from fixtures f cross join wat_set_items i;
insert into processing_jobs(id, user_id, session_id, type, max_attempts)
select job_id, user_id, session_id, 'feedback', 2 from fixtures;
insert into processing_jobs(id, user_id, type, max_attempts)
select export_job_id, user_id, 'export', 3 from fixtures;
insert into feedback_reports(id, user_id, session_id, job_id, rubric_version, prompt_version,
 model_provider, model_name, narrative, overall_score)
select report_id, user_id, session_id, job_id, 'wat-rubric-v1', 'wat-feedback-2026-10-01',
 'google_gemini', 'test-model', 'Synthetic report.', 8.0 from fixtures;
insert into feedback_items(report_id, user_id, session_id, position, status,
 tone_rating, agency_rating, clarity_rating, realism_rating, strength, feedback)
select f.report_id, f.user_id, f.session_id, i.position, 'scored', 4, 4, 4, 4,
 'Synthetic strength.', 'Synthetic feedback.' from fixtures f cross join wat_set_items i;
insert into usage_reservations(user_id, session_id, job_id, type, operation_key)
select user_id, session_id, job_id, 'report', job_id::text from fixtures;
insert into legacy_imports(user_id, session_id, client_session_id, source, request_hash)
select user_id, session_id, 'guest-fixture', 'guest_local', repeat('1', 64) from fixtures;
insert into data_exports(id, user_id, job_id) select export_id, user_id, export_job_id from fixtures;
insert into paper_uploads(id, session_id, user_id, page_number, content_type, size_bytes, sha256, object_path)
select upload_id, paper_session_id, user_id, 1, 'image/jpeg', 1024, repeat('2', 64),
 user_id::text || '/' || paper_session_id::text || '/' || upload_id::text || '.jpg' from fixtures;
insert into ocr_drafts(session_id, user_id, ocr_revision, position, ocr_text, confidence)
select paper_session_id, user_id, 1, 1, 'Synthetic draft.', 0.9 from fixtures;
insert into payment_offers(id, code, name, amount_minor, accepted_methods, instructions)
values ('00000000-1000-0000-0000-000000000001', 'test-only', 'Synthetic offer', 100,
 array['easypaisa']::payment_method[], 'Test only.');
insert into payment_submissions(user_id, offer_id, offer_code, currency, amount_minor,
 access_days, payment_method, transaction_id_ciphertext, transaction_id_hash, transaction_id_masked)
select user_id, '00000000-1000-0000-0000-000000000001', 'test-only', 'PKR', 100, 30, 'easypaisa',
 decode('00', 'hex'), private.payment_transaction_hash('easypaisa', user_id::text), '********0001' from fixtures;
insert into api_idempotency_keys(user_id, route, idempotency_key, request_hash)
select user_id, 'POST /wat/sessions/import', 'synthetic-key-0001', repeat('3', 64) from fixtures;
insert into admin_audit_log(actor_id, subject_id, action, request_id)
values ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001',
 'admin_added', gen_random_uuid());
insert into deletion_requests(user_id, subject_id) select user_id, gen_random_uuid() from fixtures;
-- Trusted fixture setup restores access solely to exercise populated deletion-row RLS.
update profiles set access_disabled_at = null where id in (select user_id from fixtures);

create temp table table_matrix(table_name text, candidate_read boolean, column_name text);
insert into table_matrix values
 ('profiles', true, 'id'), ('profile_consents', true, 'id'), ('admin_users', false, 'user_id'),
 ('entitlements', true, 'id'), ('payment_offers', false, 'id'), ('payment_submissions', true, 'id'),
 ('wat_sets', false, 'id'), ('wat_set_items', false, 'id'), ('wat_sessions', true, 'id'),
 ('wat_responses', true, 'id'), ('paper_uploads', true, 'id'), ('ocr_drafts', true, 'id'),
 ('processing_jobs', true, 'id'), ('feedback_reports', true, 'id'), ('feedback_items', true, 'id'),
 ('usage_reservations', false, 'id'), ('legacy_imports', true, 'id'), ('data_exports', true, 'id'),
 ('deletion_requests', true, 'id'), ('admin_audit_log', false, 'id'), ('app_settings', false, 'key'),
 ('api_idempotency_keys', false, 'id');
grant select on table_matrix to anon, authenticated, service_role;

select is((select count(*)::integer from pg_tables where schemaname = 'public'), 22,
 'Exactly all 22 application tables exist');
select ok(c.relrowsecurity and c.relforcerowsecurity, m.table_name || ': RLS enabled and forced')
from table_matrix m join pg_class c on c.oid = ('public.' || m.table_name)::regclass;
select ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = required.name),
 'Required index exists: ' || required.name)
from unnest(array['jobs_processing_idx', 'jobs_recovery_idx', 'sessions_history_idx',
 'usage_owner_idx', 'uploads_expiry_idx', 'exports_expiry_idx', 'sessions_expiry_idx',
 'entitlements_expiry_idx', 'idempotency_expiry_idx', 'payment_one_pending_per_user',
 'session_one_in_progress_per_user', 'exports_one_active_per_user']) as required(name);

set local role anon;
select is(pg_temp.sqlstate(format('select %I from public.%I', column_name, table_name)), '42501',
 table_name || ': anonymous read denied') from table_matrix;
reset role;

set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated","user_metadata":{"role":"admin"}}';
set local role authenticated;
select is(pg_temp.sqlstate(format('select %I from public.%I', column_name, table_name)),
 case when candidate_read then '00000' else '42501' end,
 table_name || ': candidate read grant is explicit') from table_matrix;
select is(pg_temp.sqlstate(format('insert into public.%I default values', table_name)), '42501',
 table_name || ': candidate insert denied') from table_matrix;
select is(pg_temp.sqlstate(format('update public.%I set %I = %I', table_name, column_name, column_name)), '42501',
 table_name || ': candidate protected update denied') from table_matrix;
select is(pg_temp.sqlstate(format('delete from public.%I', table_name)), '42501',
 table_name || ': candidate delete denied') from table_matrix;

-- Separate safe profile UPDATE proves cross-user writes affect zero rows.
select lives_ok($$update profiles set display_name = 'Candidate A', timezone = 'Asia/Karachi'
 where id = '00000000-0000-0000-0000-000000000001'$$, 'Candidate can edit safe preferences');
with changed as (update profiles set display_name = 'Attack'
 where id = '00000000-0000-0000-0000-000000000002' returning id)
select is((select count(*)::integer from changed), 0, 'Candidate cannot edit another profile');
select is(pg_temp.sqlstate($$update profiles set role = 'candidate'$$), '42501', 'Candidate cannot write even its own role');
select is(pg_temp.sqlstate($$update profiles set access_disabled_at = null$$), '42501', 'Candidate cannot re-enable access');
select is(pg_temp.sqlstate($$select transaction_id_ciphertext from payment_submissions$$), '42501', 'Payment ciphertext hidden');
select is(pg_temp.sqlstate($$select transaction_id_hash from payment_submissions$$), '42501', 'Payment hash hidden');
select is(pg_temp.sqlstate($$select verification_note from payment_submissions$$), '42501', 'Admin verification note hidden');
select is(pg_temp.sqlstate($$select object_path from paper_uploads$$), '42501', 'Paper path hidden');
select is(pg_temp.sqlstate($$select object_path from data_exports$$), '42501', 'Export path hidden');
select is(pg_temp.sqlstate($$select locked_by from processing_jobs$$), '42501', 'Worker internals hidden');
select is(pg_temp.sqlstate($$select private.is_active_admin('00000000-0000-0000-0000-000000000001')$$),
 '42501', 'Browser cannot invoke trusted admin lookup');
select is(pg_temp.sqlstate($$select private.payment_transaction_hash('easypaisa', 'synthetic')$$),
 '42501', 'Browser cannot invoke trusted payment hashing helper');
reset role;

create function pg_temp.read_count(table_name text, owner_id uuid) returns integer
language plpgsql security invoker as $$
declare count_rows integer;
begin
  execute format('select count(*) from public.%I where %I = $1', table_name,
    case when table_name = 'profiles' then 'id' else 'user_id' end)
    into count_rows using owner_id;
  return count_rows;
end;
$$;
grant execute on function pg_temp.read_count(text, uuid) to authenticated, service_role;
set local role authenticated;
select ok(pg_temp.read_count(table_name, '00000000-0000-0000-0000-000000000001') > 0,
 table_name || ': A reads own populated fixture') from table_matrix where candidate_read;
select is(pg_temp.read_count(table_name, '00000000-0000-0000-0000-000000000002'), 0,
 table_name || ': A cannot read B') from table_matrix where candidate_read;
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}';
set local role authenticated;
select is(pg_temp.read_count(table_name, '00000000-0000-0000-0000-000000000001'), 0,
 table_name || ': B cannot read A') from table_matrix where candidate_read;
reset role;

-- An actual allowlisted admin JWT is still not a privileged browser database client.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}';
set local role authenticated;
select is(pg_temp.sqlstate(format('select %I from public.%I', column_name, table_name)),
 case when candidate_read then '00000' else '42501' end,
 table_name || ': allowlisted browser admin has no additional table privilege') from table_matrix;
select is(pg_temp.read_count(table_name, '00000000-0000-0000-0000-000000000001'), 0,
 table_name || ': browser admin cannot read candidate A') from table_matrix where candidate_read;
select is(pg_temp.sqlstate($$update payment_submissions set status = 'approved'$$), '42501', 'Browser admin cannot approve payments');
reset role;

set local role service_role;
select is(pg_temp.sqlstate(format('select %I from public.%I', column_name, table_name)), '00000',
 table_name || ': isolated service context can read operational data') from table_matrix;
select ok(private.is_active_admin('00000000-0000-0000-0000-000000000003'), 'Service verifies actual allowlisted admin');
select ok(not private.is_active_admin('00000000-0000-0000-0000-000000000001'), 'Service rejects metadata-spoofed admin');
select lives_ok($$insert into entitlements(user_id, type) values
 ('00000000-0000-0000-0000-000000000003', 'diagnostic')$$, 'Service can grant entitlement');
select is(pg_temp.sqlstate($$update admin_audit_log set action = 'admin_removed'$$), '42501', 'Service cannot overwrite audit');
select is(pg_temp.sqlstate($$delete from admin_audit_log$$), '42501', 'Service cannot delete audit');
select is(pg_temp.sqlstate($$truncate admin_audit_log$$), '42501', 'Service cannot truncate audit');
reset role;

-- Database invariants, including privileged writes: no client behavior can bypass them.
select is(pg_temp.sqlstate($$update wat_sets set answer_grace_ms = 3000 where code = 'diagnostic-v1'$$),
 '23514', 'Published set metadata immutable even to DB owner');
select is(pg_temp.sqlstate($$delete from wat_sets where code = 'diagnostic-v1'$$), '23514', 'Published set cannot be deleted');
select is(pg_temp.sqlstate($$update wat_set_items set word = 'Modified' where position = 1$$), '23514', 'Published word cannot change');
select is(pg_temp.sqlstate($$delete from wat_set_items where position = 1$$), '23514', 'Published word cannot be deleted');
select is(pg_temp.sqlstate($$insert into wat_set_items(wat_set_id, version, position, word)
 values ('7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1', 1, 1, 'Injected')$$), '23514', 'Published word cannot be inserted');
select is(pg_temp.sqlstate($$update admin_audit_log set action = 'admin_removed'$$), '23514', 'Audit immutable trigger protects DB-owner updates');

insert into wat_sets(id, code, version, kind) values ('00000000-2000-0000-0000-000000000001', 'draft-test', 1, 'practice');
insert into wat_set_items(wat_set_id, version, position, word)
values ('00000000-2000-0000-0000-000000000001', 1, 1, 'Draft');
select is(pg_temp.sqlstate($$update wat_sets set published_at = now() where code = 'draft-test'$$),
 '23514', 'Incomplete WAT set cannot be published');
select is(pg_temp.sqlstate($$insert into wat_set_items(wat_set_id, version, position, word)
 values ('00000000-2000-0000-0000-000000000001', 1, 1, 'Other')$$), '23505', 'Set/version/position unique');
select is(pg_temp.sqlstate($$insert into wat_set_items(wat_set_id, version, position, word)
 values ('00000000-2000-0000-0000-000000000001', 1, 2, 'DRAFT')$$), '23505', 'Normalized set word unique');
select is(pg_temp.sqlstate($$insert into wat_set_items(wat_set_id, version, position, word)
 values ('00000000-2000-0000-0000-000000000001', 1, 21, 'Other')$$), '23514', 'Set position 21 rejected');
select is(pg_temp.sqlstate($$insert into wat_set_items(wat_set_id, version, position, word)
 values ('00000000-2000-0000-0000-000000000001', 1, 0, 'Other')$$), '23514', 'Set position zero rejected');

select is(pg_temp.sqlstate($$insert into wat_sessions(user_id, client_session_id, wat_set_id,
 set_version, kind, practice_mode, response_mode, status, source, timing_trust, finished_at, imported_at)
 values ('00000000-0000-0000-0000-000000000001', 'guest-fixture',
 '7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1', 1, 'diagnostic', 'training', 'typing',
 'finished', 'guest_local', 'client_reported', now(), now())$$), '23505', 'User/client-session idempotency enforced');
insert into wat_sessions(id, user_id, client_session_id, wat_set_id, set_version, kind, practice_mode, response_mode)
values ('00000000-3000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
 'active-test', '7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1', 1, 'diagnostic', 'simulation', 'typing');
select is(pg_temp.failure_constraint($$insert into wat_sessions(user_id, client_session_id,
 wat_set_id, set_version, kind, practice_mode, response_mode) values
 ('00000000-0000-0000-0000-000000000001', 'second-active',
 '7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1', 1, 'diagnostic', 'simulation', 'typing')$$),
 'session_one_in_progress_per_user', 'Only one active server session per user');
select is(pg_temp.sqlstate($$update wat_sessions set status = 'ready', finished_at = now()
 where id = '00000000-3000-0000-0000-000000000001'$$), '23514', 'Cannot skip session state transitions');
select is(pg_temp.sqlstate($$update wat_sessions set status = 'invalid'$$), '22P02', 'Unknown session state rejected');
select is(pg_temp.sqlstate($$update wat_sessions set practice_mode = 'exam'$$), '22P02', 'Unknown practice mode rejected');
select is(pg_temp.sqlstate($$update wat_sessions set response_mode = 'audio'$$), '22P02', 'Unknown response mode rejected');
select is(pg_temp.sqlstate($$update wat_sessions set session_size = 40$$), '23514', 'Non-v1 session size rejected');
select is(pg_temp.sqlstate($$update wat_sessions set finished_at = now() - interval '1 day'
 where id = '00000000-3000-0000-0000-000000000001'$$), '23514', 'Finish before start rejected');
select is(pg_temp.sqlstate($$update wat_sessions set started_at = 'infinity'$$), '23514', 'Infinite session dates rejected');
select is(pg_temp.sqlstate($$update profiles set timezone = 'Not/A_Timezone'$$), '23514', 'Invalid timezone rejected');
select lives_ok($$update profiles set timezone = 'UTC'
 where id = '00000000-0000-0000-0000-000000000003'$$, 'Valid IANA UTC alias accepted');
select is(pg_temp.sqlstate($$update profiles set display_name = repeat('x', 81)$$), '23514', 'Oversized display name rejected');
select is(pg_temp.sqlstate($$update profiles set display_name = '   '$$), '23514', 'Blank display name rejected');
select is(pg_temp.sqlstate($$update profiles set created_at = 'infinity'$$), '23514', 'Non-finite creation date rejected');
select is(pg_temp.sqlstate($$select 'not-a-date'::timestamptz$$), '22007', 'Malformed timestamp rejected');
select is(pg_temp.sqlstate(format('select %L::public.%I', 'unknown-enum-value', t.typname)),
 '22P02', 'Unknown value rejected for enum ' || t.typname)
from pg_type t join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public' and t.typtype = 'e';

select is(pg_temp.sqlstate($$insert into wat_responses(session_id, user_id, position, word,
 answer, source, status, completed) values ('10000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000001', 1, 'Courage', 'Duplicate', 'typed', 'answered', true)$$),
 '23505', 'One answer per session position');
select is(pg_temp.sqlstate($$insert into wat_responses(session_id, user_id, position, word, source)
 values ('00000000-3000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 1, 'Courage', 'typed')$$),
 '23503', 'Composite owner FK rejects mismatched response owner');
select is(pg_temp.sqlstate($$insert into wat_responses(session_id, user_id, position, word, source)
 values ('00000000-3000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 21, 'Other', 'typed')$$),
 '23514', 'Response position 21 rejected');
select is(pg_temp.sqlstate($$update wat_responses set answer = repeat('x', 281)$$), '23514', '281-code-point answer rejected');
select lives_ok($$update wat_responses set answer = repeat('x', 280) where position = 1$$, '280-code-point answer accepted');
select lives_ok($$update wat_responses set answer = U&'e\0301' || E'\r\ntext' where position = 2$$,
 'Unicode and line endings normalize');
select is((select answer from wat_responses where session_id = '10000000-0000-0000-0000-000000000001' and position = 2),
 U&'\00E9' || E'\ntext', 'Answer persisted as NFC and LF');
select is(pg_temp.sqlstate($$update wat_responses set time_used_ms = -1$$), '23514', 'Negative timing rejected');
select is(pg_temp.sqlstate($$update wat_responses set status = 'blank' where position = 1$$), '23514', 'Blank status requires blank answer');
update wat_responses set locked = true where position = 3;
select is(pg_temp.sqlstate($$update wat_responses set answer = 'Replaced' where position = 3$$), '23514', 'Locked answer immutable');

select is(pg_temp.sqlstate($$insert into feedback_reports(user_id, session_id, job_id, rubric_version,
 prompt_version, model_provider, model_name, narrative) select user_id, session_id, job_id,
 'wat-rubric-v1', 'test', 'google_gemini', 'test-model', 'Duplicate.' from fixtures limit 1$$),
 '23505', 'One final report per session/rubric');
select is(pg_temp.sqlstate($$update feedback_reports set overall_score = 10.1$$), '23514', 'Report score over 10 rejected');
select is(pg_temp.sqlstate($$update feedback_reports set overall_score = -0.1$$), '23514', 'Negative score rejected');
select is(pg_temp.sqlstate($$update feedback_items set tone_rating = 0$$), '23514', 'Rating zero rejected');
select is(pg_temp.sqlstate($$update feedback_items set agency_rating = 6$$), '23514', 'Rating six rejected');
select is(pg_temp.sqlstate($$update feedback_items set safety_flags = array['diagnosis']::safety_flag[]$$),
 '22P02', 'Unknown safety flag rejected');
select is((select score::text from feedback_items limit 1), '8.0', 'Sentence score deterministically derived from integer ratings');
select is(pg_temp.sqlstate($$update feedback_items set status = 'not_scored'$$), '23514', 'Unscored items cannot retain ratings');
select is(pg_temp.sqlstate($$insert into feedback_items(report_id, user_id, session_id, position, status, feedback)
 select report_id, user_id, session_id, 1, 'not_scored', 'Blank.' from fixtures limit 1$$), '23505', 'One feedback item per report position');
select is(pg_temp.sqlstate($$update ocr_drafts set confidence = 1.1$$), '23514', 'Invalid OCR confidence rejected');
select is(pg_temp.sqlstate($$update processing_jobs set max_attempts = 3 where type = 'feedback'$$), '23514', 'Feedback retries bounded at two attempts');
select is(pg_temp.sqlstate($$update processing_jobs set attempt = 4$$), '23514', 'Job cannot exceed retry budget');
select is(pg_temp.sqlstate($$update processing_jobs set status = 'processing'$$), '23514', 'Processing requires worker lock');
select is(pg_temp.sqlstate($$update processing_jobs set status = 'succeeded'$$), '23514', 'Terminal job needs completion timestamp');

select is(private.payment_transaction_hash('easypaisa', E' \tTEST-REF-1\n '),
 private.payment_transaction_hash('easypaisa', 'TEST-REF-1'), 'Transaction reference trims surrounding whitespace');
select is(pg_temp.sqlstate($$select private.payment_transaction_hash('easypaisa', repeat('x', 101))$$),
 '23514', 'Normalized transaction max 100 characters');
select is(pg_temp.sqlstate($$select private.payment_transaction_hash('easypaisa', '   ')$$), '23514', 'Blank normalized reference rejected');
select is(pg_temp.failure_constraint($$insert into payment_submissions(user_id, offer_id, offer_code,
 currency, amount_minor, access_days, payment_method, transaction_id_ciphertext, transaction_id_hash, transaction_id_masked)
 values ('00000000-0000-0000-0000-000000000003', '00000000-1000-0000-0000-000000000001',
 'test-only', 'PKR', 100, 30, 'easypaisa', decode('00', 'hex'),
 private.payment_transaction_hash('easypaisa', ' 00000000-0000-0000-0000-000000000001 '), '********0001')$$),
 'payment_submissions_payment_method_transaction_id_hash_key', 'Globally unique normalized provider transaction');
select is(pg_temp.failure_constraint($$insert into payment_submissions(user_id, offer_id, offer_code,
 currency, amount_minor, access_days, payment_method, transaction_id_ciphertext, transaction_id_hash, transaction_id_masked)
 values ('00000000-0000-0000-0000-000000000001', '00000000-1000-0000-0000-000000000001',
 'test-only', 'PKR', 100, 30, 'easypaisa', decode('00', 'hex'), repeat('f', 64), '********0002')$$),
 'payment_one_pending_per_user', 'One pending payment per user');
select is(pg_temp.sqlstate($$update payment_submissions set status = 'approved'$$), '23514', 'Payment cannot be approved without decision data');
select is(pg_temp.sqlstate($$update entitlements set expires_at = starts_at - interval '1 second'$$), '23514', 'Entitlement expiry must follow start');
select is(pg_temp.sqlstate($$insert into entitlements(user_id, type) values
 ('00000000-0000-0000-0000-000000000001', 'founding_30d')$$), '23514', 'Paid entitlement must have exact 30-day window');
set local role service_role;
select is(pg_temp.sqlstate($$update payment_submissions set status = 'approved',
 decided_at = now(), decided_by = '00000000-0000-0000-0000-000000000001'
 where user_id = '00000000-0000-0000-0000-000000000002'$$), '23514',
 'Trusted path still rejects a non-allowlisted decision actor');
select lives_ok($$update payment_submissions set status = 'approved', decided_at = now(),
 decided_by = '00000000-0000-0000-0000-000000000003', verification_note = 'Synthetic verification.'
 where user_id = '00000000-0000-0000-0000-000000000002'$$,
 'Isolated service can record an allowlisted admin decision');
select is(pg_temp.sqlstate($$update payment_submissions set status = 'pending',
 decided_at = null, decided_by = null, verification_note = null
 where user_id = '00000000-0000-0000-0000-000000000002'$$), '23514', 'Payment decision cannot be reversed');
reset role;
update admin_users set active = false where user_id = '00000000-0000-0000-0000-000000000003';
set local role service_role;
select ok(not private.is_active_admin('00000000-0000-0000-0000-000000000003'), 'Inactive admin membership grants no authority');
reset role;
update admin_users set active = true where user_id = '00000000-0000-0000-0000-000000000003';

select is(pg_temp.sqlstate($$insert into legacy_imports(user_id, session_id, client_session_id, source, request_hash)
 select user_id, session_id, 'guest-fixture', 'guest_local', repeat('3', 64) from fixtures limit 1$$), '23505', 'Import idempotency unique');
select is(pg_temp.sqlstate($$insert into api_idempotency_keys(user_id, route, idempotency_key, request_hash)
 select user_id, 'POST /wat/sessions/import', 'synthetic-key-0001', repeat('3', 64) from fixtures limit 1$$),
 '23505', 'API idempotency unique per user and route');
select is(pg_temp.sqlstate($$update api_idempotency_keys set idempotency_key = 'short'$$), '23514', 'Short idempotency key rejected');
select is(pg_temp.sqlstate($$update api_idempotency_keys set idempotency_key = repeat(U&'\00E9', 20)$$), '23514', 'Non-ASCII idempotency key rejected');
select is(pg_temp.sqlstate($$update api_idempotency_keys set expires_at = created_at + interval '23 hours'$$), '23514', 'Idempotency retained at least 24 hours');
select is(pg_temp.sqlstate($$insert into processing_jobs(user_id, session_id, type, max_attempts)
 select user_id, session_id, 'feedback', 2 from fixtures limit 1$$), '23505', 'Only one active feedback job per session');
select is(pg_temp.sqlstate($$insert into usage_reservations(user_id, session_id, job_id, type, operation_key)
 select user_id, session_id, job_id, 'report', job_id::text from fixtures limit 1$$), '23505', 'Provider/report replay cannot double reserve');
select is(pg_temp.sqlstate($$update usage_reservations set amount = 0$$), '23514', 'Usage amount cannot be zero');
select is(pg_temp.sqlstate($$insert into legacy_imports(user_id, session_id, client_session_id, source, request_hash)
 values ('00000000-0000-0000-0000-000000000001', '00000000-3000-0000-0000-000000000001',
 'different-client-session', 'guest_local', repeat('3', 64))$$), '23503', 'Import tracking must match canonical client-session identity');
insert into processing_jobs(id, user_id, type, max_attempts) values ('00000000-4000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000001', 'export', 3);
select is(pg_temp.failure_constraint($$insert into data_exports(user_id, job_id) values
 ('00000000-0000-0000-0000-000000000001', '00000000-4000-0000-0000-000000000001')$$),
 'exports_one_active_per_user', 'One active export per user');
select is(pg_temp.sqlstate($$update data_exports set status = 'ready'$$), '23514', 'Ready export requires file metadata');
select is(pg_temp.sqlstate($$update paper_uploads set upload_expires_at = created_at + interval '901 seconds'$$), '23514', 'Upload authorization cannot extend expiry');
select is(pg_temp.sqlstate($$insert into paper_uploads(session_id, user_id, page_number, content_type,
 size_bytes, sha256, object_path) values ('20000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000001', 5, 'image/jpeg', 1024, repeat('2', 64), 'invalid')$$), '23514', 'Invalid page number/path rejected');

-- Expired but otherwise correctly issued own authorization is insufficient.
insert into paper_uploads(id, session_id, user_id, page_number, content_type, size_bytes,
 sha256, object_path, created_at, updated_at, upload_expires_at, expires_at)
values ('80000000-0000-0000-0000-000000000011', '20000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000001', 2, 'image/jpeg', 1024, repeat('2', 64),
 '00000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/80000000-0000-0000-0000-000000000011.jpg',
 now() - interval '16 minutes', now(), now() - interval '1 minute', now() + interval '23 hours');

-- Storage tests exercise policy SQL; signed URLs and byte validation need later HTTP tests.
select ok((select relrowsecurity from pg_class where oid = 'storage.objects'::regclass), 'Storage objects use RLS');
select ok(not (select public from storage.buckets where id = 'paper-uploads'), 'Paper bucket is private');
select is((select file_size_limit from storage.buckets where id = 'paper-uploads'), 8388608::bigint, 'Bucket enforces 8 MiB');
insert into storage.objects(bucket_id, name)
select 'paper-uploads', user_id::text || '/' || paper_session_id::text || '/existing.jpg' from fixtures;
-- Intentionally broad temporary policies prove restrictive bucket guards survive unrelated policies.
create policy test_broad_read on storage.objects for select to anon, authenticated using (true);
create policy test_broad_insert on storage.objects for insert to anon, authenticated with check (true);
create policy test_broad_update on storage.objects for update to anon, authenticated using (true) with check (true);
create policy test_broad_delete on storage.objects for delete to anon, authenticated using (true);
set local role anon;
select is((select count(*)::integer from storage.objects where bucket_id = 'paper-uploads'), 0, 'Anonymous cannot read/list private objects');
select is(pg_temp.sqlstate($$insert into storage.objects(bucket_id, name) values ('paper-uploads', 'public.jpg')$$),
 '42501', 'Anonymous upload denied even with unrelated broad policy');
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}';
set local role authenticated;
select is((select count(*)::integer from storage.objects where bucket_id = 'paper-uploads'), 0,
 'Candidate cannot read/list even own paper objects');
select lives_ok($$insert into storage.objects(bucket_id, name) values ('paper-uploads',
 '00000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/80000000-0000-0000-0000-000000000001.jpg')$$,
 'Candidate can insert exact own server-authorized path');
select is(pg_temp.sqlstate($$insert into storage.objects(bucket_id, name) values ('paper-uploads',
 '00000000-0000-0000-0000-000000000002/20000000-0000-0000-0000-000000000002/80000000-0000-0000-0000-000000000002.jpg')$$),
 '42501', 'Cross-user authorized path denied');
select is(pg_temp.sqlstate($$insert into storage.objects(bucket_id, name) values ('paper-uploads',
 '00000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/arbitrary.jpg')$$),
 '42501', 'Own prefix alone cannot authorize upload');
select is(pg_temp.sqlstate($$insert into storage.objects(bucket_id, name) values ('paper-uploads',
 '00000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/80000000-0000-0000-0000-000000000011.jpg')$$),
 '42501', 'Expired server-authorized own path denied');
-- Test-only opt-in to exercise SQL RLS beneath Storage's API-only deletion guard.
-- Production object cleanup must use the Storage API; this transaction rolls back.
set local storage.allow_delete_query = 'true';
with deleted as (delete from storage.objects where bucket_id = 'paper-uploads' returning id)
select is((select count(*)::integer from deleted), 0, 'Candidate cannot delete any paper object');
with changed as (update storage.objects set name = 'attack.jpg' where bucket_id = 'paper-uploads' returning id)
select is((select count(*)::integer from changed), 0, 'Candidate cannot overwrite paper objects');
reset role;
set local role service_role;
select is((select count(*)::integer from storage.objects where bucket_id = 'paper-uploads'), 3, 'Service can read cleanup objects');
set local storage.allow_delete_query = 'true';
select lives_ok($$delete from storage.objects where name like '%existing.jpg'$$, 'Service can delete temporary objects');
reset role;
update paper_uploads set status = 'uploaded', uploaded_at = now() where user_id = '00000000-0000-0000-0000-000000000001';
set local role authenticated;
select ok(not private.can_upload_paper_object(
 '00000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/80000000-0000-0000-0000-000000000001.jpg'),
 'Uploaded authorization no longer permits insertion');
reset role;

-- Deletion revokes every own candidate-facing read immediately, including old JWTs.
insert into deletion_requests(user_id, subject_id) values
 ('00000000-0000-0000-0000-000000000004', gen_random_uuid());
select ok((select access_disabled_at is not null from profiles where id = '00000000-0000-0000-0000-000000000004'),
 'Deletion request immediately disables access');
update profiles set access_disabled_at = now() where id = '00000000-0000-0000-0000-000000000001';
set local role authenticated;
select is(pg_temp.read_count(table_name, '00000000-0000-0000-0000-000000000001'), 0,
 table_name || ': disabled account cannot read with an old JWT') from table_matrix where candidate_read;
select ok(not private.can_upload_paper_object(
 '00000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/80000000-0000-0000-0000-000000000001.jpg'),
 'Disabled account cannot upload');
reset role;

-- Privileged actor IDs remain pseudonymous after admin Auth/profile erasure.
delete from auth.users where id = '00000000-0000-0000-0000-000000000003';
select is((select decided_by::text from payment_submissions
 where user_id = '00000000-0000-0000-0000-000000000002'),
 '00000000-0000-0000-0000-000000000003', 'Payment decision actor survives admin account erasure');
select ok(exists (select 1 from admin_audit_log where actor_id = '00000000-0000-0000-0000-000000000003'),
 'Audit survives admin account erasure without profile data');

select * from finish();
rollback;
