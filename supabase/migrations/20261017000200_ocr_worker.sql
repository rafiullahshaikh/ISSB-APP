begin;
alter table public.processing_jobs add column ocr_result_revision integer check (ocr_result_revision is null or ocr_result_revision>0);
create function private.paper_fenced(job_identifier uuid,worker uuid) returns public.processing_jobs
language plpgsql set search_path = '' as $$ declare j public.processing_jobs; begin
 perform private.api_assert_service();
 select * into j from public.processing_jobs where id=job_identifier and type='ocr';
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 perform 1 from public.profiles where id=j.user_id for update;
 perform 1 from public.wat_sessions where id=j.session_id for update;
 select * into j from public.processing_jobs where id=j.id for update;
 if j.status<>'processing' or j.locked_by is distinct from worker or worker is null or j.locked_at<=statement_timestamp()-interval '5 minutes' then
  perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 return j;
end $$;
create function private.paper_fail(job_identifier uuid,worker uuid,code text,retryable boolean,at_time timestamptz) returns boolean
language plpgsql set search_path = '' as $$ declare j public.processing_jobs; begin
 select * into j from public.processing_jobs where id=job_identifier for update;
 if not found or j.type<>'ocr' or j.status<>'processing' or j.locked_by is distinct from worker then return false; end if;
 if code is null or code not in ('OCR_FAILED','PROVIDER_UNAVAILABLE','INTERNAL_ERROR','UPLOAD_EXPIRED','UNSUPPORTED_MEDIA_TYPE','FEATURE_DISABLED','AUTH_INVALID','GLOBAL_QUOTA_EXHAUSTED') then code:='INTERNAL_ERROR'; end if;
 if retryable and code in ('PROVIDER_UNAVAILABLE','INTERNAL_ERROR') and j.attempt<j.max_attempts then
  update public.processing_jobs set status='retrying',locked_at=null,locked_by=null,error_code=code,
   next_attempt_at=at_time+least(60,5*power(2,j.attempt-1))*interval '1 second' where id=j.id;
  update public.wat_sessions set status='ocr_queued' where id=j.session_id;
 else
  update public.processing_jobs set status='failed',completed_at=at_time,locked_at=null,locked_by=null,error_code=code where id=j.id;
  -- A dispatched request with an unknown outcome remains reserved conservatively.
  -- Never refund a page that may have reached the provider after a timeout.
  update public.usage_reservations u set status='released',released_at=at_time
   where u.job_id=j.id and u.type='ocr_page' and u.status='reserved' and exists(select 1 from private.ocr_job_pages p
    where p.job_id=j.id and u.operation_key='ocr:'||j.id::text||':'||p.upload_id::text and p.dispatched_at is null);
  update public.wat_sessions set status='failed',technical_failure_verified_at=at_time where id=j.session_id;
 end if;
 return true;
end $$;
create function public.qiyadat_ocr_fail(p_job uuid,p_worker uuid,p_code text,p_retryable boolean) returns boolean
language plpgsql security invoker set search_path = '' as $$ declare j public.processing_jobs; begin
 perform private.api_assert_service();select * into j from public.processing_jobs where id=p_job and type='ocr';
 if not found then return false; end if;
 perform 1 from public.profiles where id=j.user_id for update;
 perform 1 from public.wat_sessions where id=j.session_id for update;
 return private.paper_fail(p_job,p_worker,p_code,coalesce(p_retryable,false),statement_timestamp());
end $$;
create function private.paper_recover(at_time timestamptz) returns integer
language plpgsql set search_path = '' as $$ declare candidate public.processing_jobs; j public.processing_jobs; n integer:=0; begin
 for candidate in select * from public.processing_jobs where type='ocr' and status='processing'
  and locked_at<=at_time-interval '5 minutes' order by locked_at,id limit 20 loop
  perform 1 from public.profiles where id=candidate.user_id for update skip locked;if not found then continue;end if;
  perform 1 from public.wat_sessions where id=candidate.session_id for update;
  select * into j from public.processing_jobs where id=candidate.id for update skip locked;
  if found and j.status='processing' and j.locked_at<=at_time-interval '5 minutes' then
   perform private.paper_fail(j.id,j.locked_by,'PROVIDER_UNAVAILABLE',true,at_time);n:=n+1;
  end if;
 end loop;return n;
end $$;
create function public.qiyadat_ocr_recover() returns integer
language plpgsql security invoker set search_path = '' as $$ begin perform private.api_assert_service();return private.paper_recover(statement_timestamp());end $$;
create function public.qiyadat_ocr_enabled() returns boolean
language plpgsql security invoker set search_path = '' as $$ begin perform private.api_assert_service();return private.api_flag('ocr_enabled');end $$;
create function public.qiyadat_ocr_claim(p_worker uuid) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare candidate public.processing_jobs; j public.processing_jobs; at_time timestamptz:=statement_timestamp(); begin
 perform private.api_assert_service();if p_worker is null then perform private.api_fail('VALIDATION_ERROR');end if;
 for candidate in select * from public.processing_jobs where type='ocr' and status in ('queued','retrying')
  and next_attempt_at<=at_time order by next_attempt_at,created_at,id limit 20 loop
  perform 1 from public.profiles where id=candidate.user_id for update skip locked;if not found then continue;end if;
  perform 1 from public.wat_sessions where id=candidate.session_id for update;
  select * into j from public.processing_jobs where id=candidate.id for update skip locked;
  if not found or j.status not in ('queued','retrying') or j.next_attempt_at>at_time then continue;end if;
  update public.processing_jobs set status='processing',attempt=attempt+1,started_at=coalesce(started_at,at_time),locked_at=at_time,locked_by=p_worker where id=j.id returning * into j;
  update public.wat_sessions set status='ocr_processing' where id=j.session_id;
  if not private.api_flag('ocr_enabled') then perform private.paper_fail(j.id,p_worker,'FEATURE_DISABLED',false,at_time);continue;end if;
  if exists(select 1 from public.profiles where id=j.user_id and access_disabled_at is not null) then perform private.paper_fail(j.id,p_worker,'AUTH_INVALID',false,at_time);continue;end if;
  if exists(select 1 from private.ocr_job_pages where job_id=j.id and expires_at<=at_time) then perform private.paper_fail(j.id,p_worker,'UPLOAD_EXPIRED',false,at_time);continue;end if;
  return jsonb_build_object('id',j.id,'worker',p_worker,'request_id',j.request_id,'attempt',j.attempt,
   'words',(select jsonb_agg(jsonb_build_object('position',position,'word',word) order by position) from public.wat_responses where session_id=j.session_id),
   'pages',(select jsonb_agg(jsonb_build_object('id',u.id,'user_id',u.user_id,'session_id',u.session_id,'bucket_id',u.bucket_id,
    'object_path',u.object_path,'content_type',u.content_type,'size_bytes',u.size_bytes,'sha256',u.sha256,'expires_at',private.api_time(u.expires_at),
    'upload_expires_at',private.api_time(u.upload_expires_at),'uploaded_at',private.api_time(u.uploaded_at),'lines',p.lines) order by p.ordinal)
    from private.ocr_job_pages p join public.paper_uploads u on u.id=p.upload_id where p.job_id=j.id));
 end loop;return null;
end $$;
create function public.qiyadat_ocr_page_event(p_job uuid,p_worker uuid,p_upload uuid,p_event text,p_lines jsonb default null) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare j public.processing_jobs; item jsonb; page private.ocr_job_pages; at_time timestamptz:=statement_timestamp(); begin
 j:=private.paper_fenced(p_job,p_worker);perform private.paper_enabled();
 if not exists(select 1 from public.profiles where id=j.user_id and access_disabled_at is null) then perform private.api_fail('AUTH_INVALID');end if;
 perform 1 from private.ocr_job_pages p join public.paper_uploads u on u.id=p.upload_id where p.job_id=j.id and p.upload_id=p_upload
  and p.expires_at>at_time and u.status='uploaded' and u.expires_at>at_time;
 if not found then perform private.api_fail('UPLOAD_EXPIRED'); end if;
 case p_event
 when 'dispatch' then
  select * into page from private.ocr_job_pages where job_id=j.id and upload_id=p_upload for update;
  if page.last_dispatch_attempt=j.attempt then return true;end if;
  if not private.paper_cap(at_time,case when page.dispatched_at is null then 0 else 1 end,true) then perform private.api_fail('GLOBAL_QUOTA_EXHAUSTED');end if;
  update private.ocr_job_pages set dispatched_at=coalesce(dispatched_at,at_time),last_dispatch_attempt=j.attempt where job_id=j.id and upload_id=p_upload;
 when 'accepted' then
  update private.ocr_job_pages set accepted_at=coalesce(accepted_at,at_time) where job_id=j.id and upload_id=p_upload and dispatched_at is not null;
  if not found then perform private.api_fail('SESSION_STATE_CONFLICT');end if;
  update public.usage_reservations set status='consumed',consumed_at=at_time where job_id=j.id and type='ocr_page' and status='reserved'
   and operation_key='ocr:'||j.id::text||':'||p_upload::text;
 when 'done' then
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines)>500 then perform private.api_fail('OCR_FAILED');end if;
  for item in select value from jsonb_array_elements(p_lines) loop
   perform private.api_fields(item,array['text','confidence'],array['text']);perform private.api_string(item,'text',0,10000);
   if not item ? 'confidence' or (item->'confidence'<>'null'::jsonb and (jsonb_typeof(item->'confidence')<>'number' or (item->>'confidence')::numeric not between 0 and 1)) then perform private.api_fail('OCR_FAILED');end if;
  end loop;
  update private.ocr_job_pages set lines=p_lines where job_id=j.id and upload_id=p_upload and accepted_at is not null;
  if not found then perform private.api_fail('SESSION_STATE_CONFLICT');end if;
 else perform private.api_fail('INVALID_REQUEST');end case;
 return true;
end $$;
create function public.qiyadat_ocr_complete(p_job uuid,p_worker uuid,p_draft jsonb) returns integer
language plpgsql security invoker set search_path = '' as $$
declare j public.processing_jobs; revision integer; item jsonb; n integer:=0; at_time timestamptz:=statement_timestamp(); expiry timestamptz; begin
 perform private.api_assert_service();select * into j from public.processing_jobs where id=p_job and type='ocr';
 if j.status='succeeded' then return j.ocr_result_revision;end if;
 j:=private.paper_fenced(p_job,p_worker);perform private.paper_enabled();
 if exists(select 1 from private.ocr_job_pages where job_id=j.id and (lines is null or expires_at<=at_time)) then perform private.api_fail('SESSION_STATE_CONFLICT');end if;
 if jsonb_typeof(p_draft) is distinct from 'array' or jsonb_array_length(p_draft)<>20 then perform private.api_fail('OCR_FAILED');end if;
 select ocr_revision+1 into revision from public.wat_sessions where id=j.session_id;
 select min(expires_at) into expiry from private.ocr_job_pages where job_id=j.id;
 if expiry is null then perform private.api_fail('OCR_FAILED');end if;
 delete from public.ocr_drafts where session_id=j.session_id;
 for item in select value from jsonb_array_elements(p_draft) loop
  n:=n+1;perform private.api_fields(item,array['position','ocr_text','confidence','needs_review'],array['position','ocr_text','needs_review']);
  if private.api_integer(item,'position',1,20)<>n then perform private.api_fail('OCR_FAILED');end if;
  perform private.api_string(item,'ocr_text',0,10000);
  if not item ? 'confidence' or jsonb_typeof(item->'needs_review') is distinct from 'boolean' or (item->'confidence'<>'null'::jsonb and
   (jsonb_typeof(item->'confidence')<>'number' or (item->>'confidence')::numeric not between 0 and 1)) then perform private.api_fail('OCR_FAILED');end if;
  insert into public.ocr_drafts(session_id,user_id,ocr_revision,position,ocr_text,confidence,needs_review,created_at,updated_at,expires_at)
  values(j.session_id,j.user_id,revision,n,item->>'ocr_text',(item->>'confidence')::numeric,(item->>'needs_review')::boolean,at_time,at_time,expiry);
 end loop;
 update private.ocr_job_pages set lines=null where job_id=j.id;
 update public.processing_jobs set status='succeeded',completed_at=at_time,locked_at=null,locked_by=null,error_code=null,ocr_result_revision=revision where id=j.id;
 update public.wat_sessions set status='awaiting_confirmation',ocr_revision=revision where id=j.session_id;
 return revision;
end $$;

create function public.qiyadat_paper_cleanup_candidates(p_session_id uuid default null) returns jsonb
language plpgsql security invoker set search_path = '' as $$ declare u public.paper_uploads; paths jsonb:='[]'::jsonb; at_time timestamptz:=statement_timestamp(); begin
 perform private.api_assert_service();
 for u in select * from public.paper_uploads where (p_session_id is null or session_id=p_session_id)
  and (status='delete_pending' or (status='deleted' and exists(select 1 from storage.objects o where o.bucket_id=paper_uploads.bucket_id and o.name=paper_uploads.object_path))
   or (status<>'deleted' and expires_at<=at_time) or (status='prepared' and upload_expires_at<=at_time)) order by expires_at,id limit 50 loop
  perform 1 from public.wat_sessions where id=u.session_id for update skip locked;if not found then continue;end if;
  update public.paper_uploads set status=case when status='deleted' then status else 'delete_pending'::public.upload_status end where id=u.id;
  paths:=paths||jsonb_build_array(jsonb_build_object('id',u.id,'bucket_id',u.bucket_id,'object_path',u.object_path));
 end loop;
 delete from public.ocr_drafts where id in (select id from public.ocr_drafts where expires_at<=at_time for update skip locked);
 delete from private.ocr_job_pages where (job_id,upload_id) in (select job_id,upload_id from private.ocr_job_pages where expires_at<=at_time for update skip locked);
 -- Exact orphan keys only, never a bucket/prefix recursive removal.
 if p_session_id is null then
  paths:=paths||coalesce((select jsonb_agg(jsonb_build_object('id',null,'bucket_id',o.bucket_id,'object_path',o.name)) from
   (select bucket_id,name from storage.objects o where bucket_id='paper-uploads' and name ~ '^paper-pages/[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'
    and created_at<=at_time-interval '15 minutes' and not exists(select 1 from public.paper_uploads known where known.object_path=o.name) order by created_at,id limit 50) o),'[]'::jsonb);
 end if;
 return paths;
end $$;
create function public.qiyadat_paper_deleted(p_upload uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$ declare u public.paper_uploads; begin
 perform private.api_assert_service();select * into u from public.paper_uploads where id=p_upload;
 if not found then return false;end if;
 perform 1 from public.wat_sessions where id=u.session_id for update;
 select * into u from public.paper_uploads where id=p_upload for update;
 if u.status not in ('delete_pending','deleted') then return false;end if;
 if exists(select 1 from storage.objects where bucket_id=u.bucket_id and name=u.object_path) then return false;end if;
 update public.paper_uploads set status='deleted',deleted_at=coalesce(deleted_at,statement_timestamp()),upload_lease=null,upload_locked_at=null where id=u.id;
 return true;
end $$;
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='private' and p.proname like 'paper_%') or (n.nspname='public' and (p.proname like 'qiyadat_ocr_%' or p.proname like 'qiyadat_paper_cleanup%' or p.proname='qiyadat_paper_deleted')) loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
