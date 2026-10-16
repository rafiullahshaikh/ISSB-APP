begin;
-- Reaccepting the current disclosure after a withdrawal must append a new
-- consent event, rather than treating an older accepted event as current.
create or replace function private.api_patch_profile(actor uuid,body jsonb) returns jsonb
language plpgsql set search_path = '' as $$ declare version text; display text; zone text; begin
 perform private.api_fields(body,array['display_name','timezone','accept_ai_processing_terms_version'],array[]::text[]);
 if body='{}'::jsonb then perform private.api_fail('VALIDATION_ERROR','body','At least one field is required.'); end if;
 if body ? 'display_name' then
  display:=regexp_replace(private.api_string(body,'display_name',1,10000),'^\s+|\s+$','','g');
  if char_length(display) not between 1 and 80 then perform private.api_fail('VALIDATION_ERROR','display_name','Must be 1 to 80 trimmed characters.'); end if;
 end if;
 if body ? 'timezone' then
  zone:=private.api_string(body,'timezone',1,100);
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=zone and name not like 'posix/%' and name not like 'right/%' and name<>'localtime') then
   perform private.api_fail('VALIDATION_ERROR','timezone','Must be an IANA timezone.'); end if;
 end if;
 if body ? 'accept_ai_processing_terms_version' then
  version:=private.api_string(body,'accept_ai_processing_terms_version',1,80);
  if version is distinct from (select value#>>'{}' from public.app_settings where key='ai_processing_terms_version') then
   perform private.api_fail('VALIDATION_ERROR','accept_ai_processing_terms_version','Only the current terms can be accepted.'); end if;
 end if;
 update public.profiles set display_name=case when body ? 'display_name' then display else display_name end,
  timezone=case when body ? 'timezone' then zone else timezone end where id=actor;
 if version is not null and not private.feedback_consent(actor) then
  insert into public.profile_consents(user_id,terms_version,accepted,accepted_at) values(actor,version,true,statement_timestamp());
 end if;
 return jsonb_build_object('status',200,'body',jsonb_build_object('data',jsonb_build_object('id',actor)));
end $$;
create function public.qiyadat_report_read(p_session_id uuid) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare report public.feedback_reports; begin
 if auth.uid() is null or not private.candidate_can_access(auth.uid()) then raise exception using errcode='P0001',message='AUTH_INVALID'; end if;
 if not exists(select 1 from public.wat_sessions where id=p_session_id and user_id=auth.uid()) then raise exception using errcode='P0001',message='NOT_FOUND'; end if;
 select * into report from public.feedback_reports where session_id=p_session_id and user_id=auth.uid();
 if not found then raise exception using errcode='P0001',message='SESSION_STATE_CONFLICT'; end if;
 return jsonb_build_object('id',report.id,'session_id',report.session_id,'status',report.status,'rubric_version',report.rubric_version,
  'prompt_version',report.prompt_version,'model_provider',report.model_provider,'model_name',report.model_name,
  'generated_at',report.generated_at,'overall_score',report.overall_score,'tone_score',report.tone_score,
  'agency_score',report.agency_score,'clarity_score',report.clarity_score,'realism_score',report.realism_score,
  'summary',report.summary,'sentences',(select jsonb_agg(jsonb_build_object(
   'position',f.position,'word',r.word,'response',r.answer,'response_source',r.source,'status',f.status,'score',f.score,
   'tone_rating',f.tone_rating,'agency_rating',f.agency_rating,'clarity_rating',f.clarity_rating,'realism_rating',f.realism_rating,
   'rating_notes',f.rating_notes,'strength',f.strength,'feedback',f.feedback,'safety_flags',f.safety_flags) order by f.position)
   from public.feedback_items f join public.wat_responses r on r.session_id=f.session_id and r.position=f.position
   where f.report_id=report.id and f.user_id=auth.uid()));
end $$;
create function public.qiyadat_job_read(p_actor uuid,p_job uuid) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare j public.processing_jobs; report_id uuid; begin
 perform private.api_actor(p_actor);
 select * into j from public.processing_jobs where id=p_job and (user_id=p_actor or private.is_active_admin(p_actor));
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 if j.type='feedback' and j.status='succeeded' then select id into report_id from public.feedback_reports where job_id=j.id; end if;
 return jsonb_build_object('id',j.id,'type',j.type,'status',j.status,'attempt',j.attempt,
  'created_at',private.api_time(j.created_at),'started_at',private.api_time(j.started_at),'completed_at',private.api_time(j.completed_at),
  'result',case when report_id is not null then jsonb_build_object('session_id',j.session_id,'report_id',report_id,'next_action','view_report') else null end,
  'error_code',case when j.status='failed' then j.error_code end);
end $$;
revoke all on function public.qiyadat_report_read(uuid) from public,anon;
grant execute on function public.qiyadat_report_read(uuid) to authenticated;
revoke all on function public.qiyadat_job_read(uuid,uuid) from public,anon,authenticated;
grant execute on function public.qiyadat_job_read(uuid,uuid) to service_role;
notify pgrst,'reload schema';
commit;
