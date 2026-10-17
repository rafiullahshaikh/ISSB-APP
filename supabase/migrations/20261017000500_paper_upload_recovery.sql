begin;
alter table public.wat_sessions add column paper_upload_failure_verified_at timestamptz
 check (paper_upload_failure_verified_at is null or isfinite(paper_upload_failure_verified_at));
alter table public.paper_uploads add column upload_failed_at timestamptz
 check (upload_failed_at is null or (isfinite(upload_failed_at) and upload_failed_at>=created_at));

create function public.qiyadat_paper_storage_failure(p_actor uuid,p_session_id uuid,p_upload uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare s public.wat_sessions; at_time timestamptz:=statement_timestamp(); begin
 perform private.api_actor(p_actor);
 select * into s from public.wat_sessions where id=p_session_id and user_id=p_actor for update;
 if not found or s.response_mode<>'paper' or s.status<>'awaiting_upload' or s.paper_confirmed_at is not null then return false;end if;
 update public.paper_uploads set status='delete_pending',upload_failed_at=at_time
  where id=p_upload and session_id=s.id and user_id=p_actor and status in ('prepared','uploaded','delete_pending');
 if not found then return false;end if;
 update public.wat_sessions set status='failed',technical_failure_verified_at=at_time,paper_upload_failure_verified_at=at_time where id=s.id;
 return true;
end $$;
revoke all on function public.qiyadat_paper_storage_failure(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.qiyadat_paper_storage_failure(uuid,uuid,uuid) to service_role;

do $$ declare definition text; before_text text; after_text text; begin
 definition:=pg_get_functiondef('private.validate_session()'::regprocedure);
 before_text:=$old$when 'awaiting_upload' then new.status='ocr_queued'$old$;
 after_text:=$new$when 'awaiting_upload' then new.status='ocr_queued' or (new.status='failed'
   and new.paper_upload_failure_verified_at is not null and new.technical_failure_verified_at is not null)$new$;
 if position(before_text in definition)=0 then raise exception 'Unexpected upload session guard';end if;
 definition:=replace(definition,before_text,after_text);
 before_text:=$old$and exists(select 1 from public.processing_jobs j where j.session_id=old.id and j.type='ocr' and j.status='failed')$old$;
 after_text:=$new$and (old.paper_upload_failure_verified_at is not null or exists(select 1 from public.processing_jobs j where j.session_id=old.id and j.type='ocr' and j.status='failed'))$new$;
 if position(before_text in definition)=0 then raise exception 'Unexpected OCR recovery guard';end if;
 execute replace(definition,before_text,after_text);

 definition:=pg_get_functiondef('public.qiyadat_paper_prepare(uuid,uuid,jsonb)'::regprocedure);
 before_text:=$old$or not exists(select 1 from public.processing_jobs where session_id=s.id and type='ocr' and status='failed')$old$;
 after_text:=$new$or not (s.paper_upload_failure_verified_at is not null or exists(select 1 from public.processing_jobs where session_id=s.id and type='ocr' and status='failed'))$new$;
 if position(before_text in definition)=0 then raise exception 'Unexpected preparation recovery guard';end if;
 definition:=replace(definition,before_text,after_text);
 before_text:=$old$perform private.api_rate(p_actor,'paper_prepare',at_time);$old$;
 after_text:=$new$if s.status<>'failed' then perform private.api_rate(p_actor,'paper_prepare',at_time);end if;$new$;
 if position(before_text in definition)=0 then raise exception 'Unexpected preparation rate guard';end if;
 definition:=replace(definition,before_text,after_text);
 before_text:=$old$if s.status='failed' then
  if exists(select 1 from public.paper_uploads where session_id=s.id and expires_at<=at_time)$old$;
 after_text:=$new$if s.status='failed' then
  perform private.api_rate(p_actor,'paper_prepare',at_time);
  if exists(select 1 from public.paper_uploads where session_id=s.id and upload_lease is not null) then perform private.api_fail('PROVIDER_UNAVAILABLE');end if;
  if exists(select 1 from public.paper_uploads where session_id=s.id and expires_at<=at_time)$new$;
 if position(before_text in definition)=0 then raise exception 'Unexpected preparation transfer guard';end if;
 execute replace(definition,before_text,after_text);

 definition:=pg_get_functiondef('public.qiyadat_paper_upload_complete(uuid,uuid,uuid,uuid,boolean)'::regprocedure);
 before_text:=$old$update public.paper_uploads set status='delete_pending',upload_lease=null,upload_locked_at=null where id=u.id;$old$;
 after_text:=$new$update public.paper_uploads set status='delete_pending',upload_lease=null,upload_locked_at=null where id=u.id;
  perform public.qiyadat_paper_storage_failure(p_actor,p_session_id,p_upload);$new$;
 if position(before_text in definition)=0 then raise exception 'Unexpected upload failure operation';end if;
 execute replace(definition,before_text,after_text);
end $$;
notify pgrst,'reload schema';
commit;
