begin;
-- Retain the complete Phase 3 guard, adding only rerun/recovery edges for
-- unconfirmed paper sessions. Abort if the expected definition has changed.
do $$ declare definition text; before_text text; after_text text; begin
 definition:=pg_get_functiondef('private.validate_session()'::regprocedure);
 before_text:=$old$when 'awaiting_confirmation' then new.status='finished'$old$;
 if position(before_text in definition)=0 then raise exception 'Unexpected session guard';end if;
 definition:=replace(definition,before_text,$new$when 'awaiting_confirmation' then new.status in ('finished','ocr_queued')$new$);
 before_text:=$old$when 'failed' then new.status='finished' and old.technical_failure_verified_at is not null
     and exists(select 1 from public.processing_jobs j where j.session_id=old.id and j.type='feedback' and j.status='failed')
     and not exists(select 1 from public.usage_reservations u where u.session_id=old.id and u.status in ('reserved','consumed'))
     and not exists(select 1 from public.feedback_reports f where f.session_id=old.id)$old$;
 after_text:=$new$when 'failed' then old.technical_failure_verified_at is not null and (
     (new.status='finished'
      and exists(select 1 from public.processing_jobs j where j.session_id=old.id and j.type='feedback' and j.status='failed')
      and not exists(select 1 from public.usage_reservations u where u.session_id=old.id and u.type in ('report','diagnostic_report') and u.status in ('reserved','consumed'))
      and not exists(select 1 from public.feedback_reports f where f.session_id=old.id))
     or (new.status in ('ocr_queued','awaiting_upload') and old.response_mode='paper' and old.paper_confirmed_at is null
      and (new.status<>'awaiting_upload' or not exists(select 1 from public.paper_uploads where session_id=old.id and status<>'deleted'))
      and exists(select 1 from public.processing_jobs j where j.session_id=old.id and j.type='ocr' and j.status='failed')
      and not exists(select 1 from public.feedback_reports f where f.session_id=old.id)))$new$;
 if position(before_text in definition)=0 then raise exception 'Unexpected feedback recovery guard';end if;
 execute replace(definition,before_text,after_text);
 definition:=pg_get_functiondef('public.qiyadat_request_report(uuid,uuid,jsonb,text)'::regprocedure);
 before_text:=$old$if s.response_mode<>'typing' then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;$old$;
 if position(before_text in definition)=0 then raise exception 'Unexpected report eligibility guard';end if;
 after_text:=$new$if s.response_mode='paper' and (s.paper_confirmed_at is null or exists(select 1 from public.wat_responses
   where session_id=s.id and (not locked or source<>'ocr_confirmed'))) then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;$new$;
 execute replace(definition,before_text,after_text);
end $$;
create or replace function public.qiyadat_job_read(p_actor uuid,p_job uuid) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare j public.processing_jobs; report_id uuid; result jsonb; begin
 perform private.api_actor(p_actor);
 select * into j from public.processing_jobs where id=p_job and (user_id=p_actor or private.is_active_admin(p_actor));
 if not found then perform private.api_fail('NOT_FOUND');end if;
 if j.type='feedback' and j.status='succeeded' then
  select id into report_id from public.feedback_reports where job_id=j.id;
  result:=jsonb_build_object('session_id',j.session_id,'report_id',report_id,'next_action','view_report');
 elsif j.type='ocr' and j.status='succeeded' then
  result:=jsonb_build_object('session_id',j.session_id,'next_action','confirm_ocr','ocr_revision',j.ocr_result_revision);
 end if;
 return jsonb_build_object('id',j.id,'type',j.type,'status',j.status,'attempt',j.attempt,
  'created_at',private.api_time(j.created_at),'started_at',private.api_time(j.started_at),'completed_at',private.api_time(j.completed_at),
  'result',result,'error_code',case when j.status='failed' then j.error_code end);
end $$;
revoke all on function public.qiyadat_job_read(uuid,uuid) from public,anon,authenticated;
grant execute on function public.qiyadat_job_read(uuid,uuid) to service_role;
notify pgrst,'reload schema';
commit;
