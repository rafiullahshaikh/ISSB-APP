begin;
alter table public.processing_jobs add column rubric_version text
 check (rubric_version is null or rubric_version='wat-rubric-v1');
alter table public.processing_jobs add column prompt_version text
 check (prompt_version is null or char_length(prompt_version) between 1 and 80);
alter table public.processing_jobs add column model_name text
 check (model_name is null or char_length(model_name) between 1 and 120);
alter table public.feedback_reports add column provider_version text not null default 'v1beta';
alter table public.feedback_reports add column model_version text
 check (model_version is null or char_length(model_version) between 1 and 120);

-- Expand safe operational codes for consent/kill-switch changes after enqueue.
alter table public.processing_jobs drop constraint processing_jobs_error_code_check;
alter table public.processing_jobs add constraint processing_jobs_error_code_check check
 (error_code in ('OCR_FAILED','AI_OUTPUT_INVALID','PROVIDER_UNAVAILABLE','VALIDATION_ERROR',
 'UPLOAD_EXPIRED','UNSUPPORTED_MEDIA_TYPE','GLOBAL_QUOTA_EXHAUSTED','INTERNAL_ERROR',
 'AI_CONSENT_REQUIRED','FEATURE_DISABLED','ENTITLEMENT_REQUIRED','AUTH_INVALID'));
create table private.feedback_provider_windows (
 window_start date primary key,
 hits integer not null check (hits>=0)
);
alter table private.feedback_provider_windows enable row level security;
alter table private.feedback_provider_windows force row level security;
revoke all on private.feedback_provider_windows from public,anon,authenticated;
grant select,insert,update,delete on private.feedback_provider_windows to service_role;
insert into public.app_settings(key,value) values ('feedback_daily_provider_cap','100') on conflict do nothing;
update public.app_settings set value=value||'{"report":30}'::jsonb where key='api_rate_limits';

create function private.feedback_consent(actor uuid) returns boolean
language sql stable set search_path = '' as $$
 select coalesce((select c.accepted and c.terms_version=(select value#>>'{}'
 from public.app_settings where key='ai_processing_terms_version')
 from public.profile_consents c where user_id=actor order by accepted_at desc,id desc limit 1),false);
$$;
create function private.feedback_quota(actor uuid,at_time timestamptz) returns jsonb
language sql stable set search_path = '' as $$
 select jsonb_build_object('used_rolling_24h',count(*),'remaining_rolling_24h',
 case when private.api_has_access(actor,at_time) then greatest(0,3-count(*)) else 0 end)
 from public.usage_reservations where user_id=actor and type in ('report','diagnostic_report')
 and status in ('reserved','consumed') and reserved_at>at_time-interval '24 hours';
$$;
create function private.feedback_cap(at_time timestamptz,consume boolean) returns boolean
language plpgsql set search_path = '' as $$
declare maximum integer; used integer; day_value date:=(at_time at time zone 'UTC')::date; begin
 select (value#>>'{}')::integer into maximum from public.app_settings where key='feedback_daily_provider_cap' for update;
 if maximum is null or maximum<1 then return false; end if;
 insert into private.feedback_provider_windows values(day_value,0) on conflict do nothing;
 select hits into used from private.feedback_provider_windows where window_start=day_value for update;
 if used>=maximum then return false; end if;
 if consume then update private.feedback_provider_windows set hits=hits+1 where window_start=day_value; end if;
 return true;
end $$;

-- Preserve every existing guard; add only trusted failed-feedback recovery.
create or replace function private.validate_session() returns trigger
language plpgsql security definer set search_path = '' as $$
declare allowed boolean; begin
 if tg_op='INSERT' then
  if not exists(select 1 from public.wat_sets where id=new.wat_set_id and version=new.set_version
   and kind=new.kind and published_at is not null) then
   raise exception using errcode='23514',message='Session requires a published WAT version'; end if;
  if (new.source='server' and new.status<>'in_progress') or (new.source<>'server' and new.status<>'finished') then
   raise exception using errcode='23514',message='Invalid initial session state'; end if;
 else
  if (new.id,new.user_id,new.client_session_id,new.wat_set_id,new.set_version,new.kind,new.practice_mode,
   new.response_mode,new.source,new.timing_trust,new.started_at,new.expires_at,new.imported_at,new.created_at)
   is distinct from (old.id,old.user_id,old.client_session_id,old.wat_set_id,old.set_version,old.kind,old.practice_mode,
   old.response_mode,old.source,old.timing_trust,old.started_at,old.expires_at,old.imported_at,old.created_at) then
   raise exception using errcode='23514',message='Session identity and timing are immutable'; end if;
  if old.finished_at is not null and new.finished_at is distinct from old.finished_at then
   raise exception using errcode='23514',message='Canonical finish time is immutable'; end if;
  if new.ocr_revision<old.ocr_revision then raise exception using errcode='23514',message='OCR revision cannot decrease'; end if;
  if new.status is distinct from old.status then
   allowed:=case old.status
    when 'in_progress' then (new.response_mode='typing' and new.status='finished') or (new.response_mode='paper' and new.status='awaiting_upload')
    when 'awaiting_upload' then new.status='ocr_queued'
    when 'ocr_queued' then new.status='ocr_processing'
    when 'ocr_processing' then new.status in ('awaiting_confirmation','ocr_queued','failed')
    when 'awaiting_confirmation' then new.status='finished'
    when 'finished' then new.status='feedback_queued'
    when 'feedback_queued' then new.status='feedback_processing'
    when 'feedback_processing' then new.status in ('ready','feedback_queued','failed')
    when 'failed' then new.status='finished' and old.technical_failure_verified_at is not null
     and exists(select 1 from public.processing_jobs j where j.session_id=old.id and j.type='feedback' and j.status='failed')
     and not exists(select 1 from public.usage_reservations u where u.session_id=old.id and u.status in ('reserved','consumed'))
     and not exists(select 1 from public.feedback_reports f where f.session_id=old.id)
    else false end;
   if not allowed then raise exception using errcode='23514',message='Invalid session state transition'; end if;
  end if;
 end if;
 return new;
end $$;

create function public.qiyadat_request_report(p_actor uuid,p_session_id uuid,p_body jsonb,p_key text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare s public.wat_sessions; j public.processing_jobs; k public.api_idempotency_keys;
 report_id uuid; at_time timestamptz:=statement_timestamp(); result jsonb; usage_kind public.usage_type; begin
 perform private.api_actor(p_actor);
 select * into s from public.wat_sessions where id=p_session_id and user_id=p_actor for update;
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 k:=private.api_reserve_key(p_actor,'POST /wat/sessions/'||s.id::text||'/report',p_key,p_body);
 perform private.api_fields(p_body,array['rubric_version'],array['rubric_version']);
 perform private.api_choice(p_body,'rubric_version',array['wat-rubric-v1']);
 if k.resource_id is not null then
  select * into j from public.processing_jobs where id=k.resource_id and user_id=p_actor and session_id=s.id;
  if j.status='succeeded' then
   select id into report_id from public.feedback_reports where session_id=s.id and job_id=j.id;
   return jsonb_build_object('status',200,'body',jsonb_build_object('data',jsonb_build_object(
    'report_id',report_id,'session_id',s.id,'status','ready')));
  end if;
 else
  if exists(select 1 from public.feedback_reports where session_id=s.id) then perform private.api_fail('REPORT_ALREADY_EXISTS'); end if;
  if s.response_mode<>'typing' then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
  if s.status='in_progress' then perform private.api_fail('SESSION_NOT_FINISHED'); end if;
  if s.status not in ('finished','feedback_queued','feedback_processing','failed') then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
  if (select count(*) from public.wat_responses where session_id=s.id)<>20 then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
  if not private.api_flag('feedback_enabled') then perform private.api_fail('FEATURE_DISABLED'); end if;
  if not private.feedback_consent(p_actor) then perform private.api_fail('AI_CONSENT_REQUIRED'); end if;
  if not private.api_has_access(p_actor,at_time) and not s.is_free_demo then perform private.api_fail('ENTITLEMENT_REQUIRED'); end if;
  perform private.api_rate(p_actor,'report',at_time);
  select * into j from public.processing_jobs where session_id=s.id and type='feedback'
   and status in ('queued','processing','retrying') for update;
  if j.id is null then
   if not private.api_has_access(p_actor,at_time) and exists(select 1 from public.usage_reservations
    where user_id=p_actor and type='diagnostic_report' and status in ('reserved','consumed')) then perform private.api_fail('DIAGNOSTIC_ALREADY_USED'); end if;
   if private.api_has_access(p_actor,at_time) and (private.feedback_quota(p_actor,at_time)->>'used_rolling_24h')::integer>=3 then
    perform private.api_fail('REPORT_LIMIT_REACHED'); end if;
   if not private.feedback_cap(at_time,false) then perform private.api_fail('GLOBAL_QUOTA_EXHAUSTED'); end if;
   if s.status='failed' then
    if s.technical_failure_verified_at is null then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
    update public.wat_sessions set status='finished' where id=s.id;
   end if;
   insert into public.processing_jobs(user_id,session_id,type,max_attempts,rubric_version,created_at,updated_at,next_attempt_at)
   values(p_actor,s.id,'feedback',2,'wat-rubric-v1',at_time,at_time,at_time) returning * into j;
   usage_kind:=case when s.is_free_demo then 'diagnostic_report'::public.usage_type else 'report'::public.usage_type end;
   insert into public.usage_reservations(user_id,session_id,job_id,type,operation_key,reserved_at)
   values(p_actor,s.id,j.id,usage_kind,j.id::text,at_time);
   update public.wat_sessions set status='feedback_queued' where id=s.id;
  end if;
  update public.api_idempotency_keys set resource_id=j.id where id=k.id;
 end if;
 result:=jsonb_build_object('status',202,'body',jsonb_build_object('data',jsonb_build_object(
  'job_id',j.id,'session_id',s.id,'type','feedback','status',j.status,'quota',private.feedback_quota(p_actor,at_time),'poll_after_ms',2000)));
 return result;
end $$;

revoke all on function public.qiyadat_request_report(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.qiyadat_request_report(uuid,uuid,jsonb,text) to service_role;
revoke all on function private.feedback_consent(uuid) from public,anon,authenticated;
revoke all on function private.feedback_quota(uuid,timestamptz) from public,anon,authenticated;
revoke all on function private.feedback_cap(timestamptz,boolean) from public,anon,authenticated;
grant execute on function private.feedback_consent(uuid),private.feedback_quota(uuid,timestamptz),private.feedback_cap(timestamptz,boolean) to service_role;
notify pgrst,'reload schema';
commit;
