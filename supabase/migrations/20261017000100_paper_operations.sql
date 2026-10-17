begin;
alter table public.wat_sessions add column paper_confirmed_at timestamptz
 check (paper_confirmed_at is null or (isfinite(paper_confirmed_at) and paper_confirmed_at>=finished_at));
alter table public.paper_uploads add column upload_lease uuid;
alter table public.paper_uploads add column upload_locked_at timestamptz;
do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='public.paper_uploads'::regclass and contype='c'
  and pg_get_constraintdef(oid) like '%object_path =%' loop
  execute format('alter table public.paper_uploads drop constraint %I',c.conname);
 end loop;
end $$;
-- Old paths remain valid for preserved Phase 1 fixtures; new authorizations use
-- only paper-pages/. No existing migration or Storage policy is weakened.
alter table public.paper_uploads add constraint paper_upload_controlled_path check (
 object_path in (user_id::text||'/'||session_id::text||'/'||id::text||
 case content_type when 'image/jpeg' then '.jpg' when 'image/png' then '.png' else '.webp' end,
 'paper-pages/'||user_id::text||'/'||session_id::text||'/'||id::text||
 case content_type when 'image/jpeg' then '.jpg' when 'image/png' then '.png' else '.webp' end));
-- New paths are writable only by the isolated relay service. Preserve legacy
-- insert-only policy behavior used by Phase 1 without permitting relay bypass.
create policy qiyadat_paper_relay_only on storage.objects as restrictive for insert to authenticated
 with check (bucket_id<>'paper-uploads' or name not like 'paper-pages/%');
update public.app_settings set value=value||'{"paper_prepare":10,"paper_upload":12,"paper_ocr":10,"paper_confirm":20}'::jsonb where key='api_rate_limits';

create table private.ocr_job_pages (
 job_id uuid not null references public.processing_jobs(id) on delete cascade,
 upload_id uuid not null references public.paper_uploads(id) on delete cascade,
 ordinal integer not null check (ordinal between 1 and 4),
 dispatched_at timestamptz,
 accepted_at timestamptz,
 last_dispatch_attempt integer not null default 0 check (last_dispatch_attempt between 0 and 3),
 lines jsonb check (lines is null or jsonb_typeof(lines)='array'),
 expires_at timestamptz not null,
 primary key(job_id,upload_id), unique(job_id,ordinal)
);
alter table private.ocr_job_pages enable row level security;
alter table private.ocr_job_pages force row level security;
revoke all on private.ocr_job_pages from public,anon,authenticated;
grant select,insert,update,delete on private.ocr_job_pages to service_role;
create index ocr_pages_expiry on private.ocr_job_pages(expires_at);
create table private.ocr_provider_windows(window_start date primary key,hits integer not null check (hits between 0 and 900));
alter table private.ocr_provider_windows enable row level security;
alter table private.ocr_provider_windows force row level security;
revoke all on private.ocr_provider_windows from public,anon,authenticated;
grant select,insert,update,delete on private.ocr_provider_windows to service_role;

create function private.paper_cap(at_time timestamptz,additional integer,dispatch boolean) returns boolean
language plpgsql set search_path = '' as $$
declare maximum integer; calls integer; outstanding integer; logical_units integer; month_value date:=date_trunc('month',at_time at time zone 'UTC')::date; begin
 select least((value#>>'{}')::integer,900) into maximum from public.app_settings where key='OCR_MONTHLY_APP_CAP' for update;
 if maximum is null or maximum<1 then return false;end if;
 insert into private.ocr_provider_windows values(month_value,0) on conflict do nothing;
 select hits into calls from private.ocr_provider_windows where window_start=month_value for update;
 select count(*) into outstanding from private.ocr_job_pages p join public.processing_jobs j on j.id=p.job_id
  where p.dispatched_at is null and p.expires_at>at_time and j.status in ('queued','processing','retrying');
 select count(*) into logical_units from public.usage_reservations where type='ocr_page' and status in ('reserved','consumed')
  and reserved_at>=month_value::timestamp at time zone 'UTC';
 if greatest(calls+outstanding,logical_units)+additional>maximum or (dispatch and calls>=maximum) then return false;end if;
 if dispatch then update private.ocr_provider_windows set hits=hits+1 where window_start=month_value;end if;
 return true;
end $$;

create function private.paper_session(actor uuid,identifier uuid,states text[]) returns public.wat_sessions
language plpgsql set search_path = '' as $$ declare s public.wat_sessions; begin
 perform private.api_actor(actor);
 select * into s from public.wat_sessions where id=identifier and user_id=actor for update;
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 if s.status='in_progress' then perform private.api_fail('SESSION_NOT_FINISHED'); end if;
 if s.response_mode<>'paper' or not s.status::text=any(states) then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 return s;
end $$;
create function private.paper_enabled() returns void language plpgsql stable set search_path = '' as $$ begin
 if not private.api_flag('ocr_enabled') then perform private.api_fail('FEATURE_DISABLED'); end if;
end $$;
create function public.qiyadat_paper_prepare(p_actor uuid,p_session_id uuid,p_body jsonb) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare s public.wat_sessions; item jsonb; n integer:=0; total bigint:=0; size_value bigint;
 mime text; hash_value text; identifier uuid; at_time timestamptz:=statement_timestamp(); existing integer; begin
 s:=private.paper_session(p_actor,p_session_id,array['awaiting_upload','failed']);perform private.paper_enabled();
 if s.status='failed' and (s.paper_confirmed_at is not null or s.technical_failure_verified_at is null
  or not exists(select 1 from public.processing_jobs where session_id=s.id and type='ocr' and status='failed')
  or exists(select 1 from public.processing_jobs where session_id=s.id and status in ('queued','processing','retrying'))
  or exists(select 1 from public.feedback_reports where session_id=s.id)) then perform private.api_fail('SESSION_STATE_CONFLICT');end if;
 perform private.api_fields(p_body,array['files'],array['files']);
 if jsonb_typeof(p_body->'files') is distinct from 'array' then perform private.api_fail('VALIDATION_ERROR'); end if;
 if jsonb_array_length(p_body->'files') not between 1 and 4 then perform private.api_fail('PAPER_UPLOAD_INCOMPLETE'); end if;
 select count(*) into existing from public.paper_uploads where session_id=s.id;
 for item in select value from jsonb_array_elements(p_body->'files') loop
  n:=n+1;
  perform private.api_fields(item,array['page_number','file_name','content_type','size_bytes','sha256'],array['page_number','file_name','content_type','size_bytes','sha256']);
  if private.api_integer(item,'page_number',1,4)<>n then perform private.api_fail('PAPER_UPLOAD_INCOMPLETE'); end if;
  if private.api_string(item,'file_name',1,255) ~ '[/\\\x00-\x1f]' then perform private.api_fail('VALIDATION_ERROR','file_name','Invalid file name.'); end if;
  mime:=private.api_string(item,'content_type',1,100);
  if mime not in ('image/jpeg','image/png','image/webp') then perform private.api_fail('UNSUPPORTED_MEDIA_TYPE'); end if;
  size_value:=private.api_integer(item,'size_bytes',1,9007199254740991);
  if size_value>8388608 then perform private.api_fail('UPLOAD_TOO_LARGE'); end if;
  total:=total+size_value;if total>25165824 then perform private.api_fail('UPLOAD_TOO_LARGE'); end if;
  hash_value:=private.api_string(item,'sha256',64,64);
  if hash_value !~ '^[0-9a-f]{64}$' then perform private.api_fail('VALIDATION_ERROR','sha256','Must be lowercase SHA-256.'); end if;
  if existing>0 and s.status='awaiting_upload' then
   if not exists(select 1 from public.paper_uploads where session_id=s.id and page_number=n
    and content_type=mime and size_bytes=size_value and sha256=hash_value and status in ('prepared','uploaded')) then
    perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
  end if;
 end loop;
 if s.status='failed' then
  if exists(select 1 from public.paper_uploads where session_id=s.id and expires_at<=at_time) then perform private.api_fail('UPLOAD_EXPIRED');end if;
  update public.paper_uploads set status='delete_pending' where session_id=s.id and status<>'deleted';
  if exists(select 1 from public.paper_uploads where session_id=s.id and status<>'deleted') then return jsonb_build_object('recovering',true);end if;
  delete from public.ocr_drafts where session_id=s.id;
  delete from public.paper_uploads where session_id=s.id;
  update public.wat_sessions set status='awaiting_upload' where id=s.id;
  existing:=0;
 end if;
 if existing>0 and existing<>n then perform private.api_fail('PAPER_UPLOAD_INCOMPLETE'); end if;
 if exists(select 1 from public.paper_uploads where session_id=s.id and upload_expires_at<=at_time) then perform private.api_fail('UPLOAD_EXPIRED'); end if;
 perform private.api_rate(p_actor,'paper_prepare',at_time);
 if existing=0 then
  for item in select value from jsonb_array_elements(p_body->'files') loop
   identifier:=gen_random_uuid();mime:=item->>'content_type';
   insert into public.paper_uploads(id,user_id,session_id,page_number,content_type,size_bytes,sha256,object_path,created_at,updated_at,upload_expires_at,expires_at)
   values(identifier,p_actor,s.id,(item->>'page_number')::integer,mime,(item->>'size_bytes')::bigint,item->>'sha256',
    'paper-pages/'||p_actor::text||'/'||s.id::text||'/'||identifier::text||case mime when 'image/jpeg' then '.jpg' when 'image/png' then '.png' else '.webp' end,
    at_time,at_time,at_time+interval '900 seconds',at_time+interval '24 hours');
  end loop;
 end if;
 return jsonb_build_object('session_id',s.id,'uploads',(select jsonb_agg(jsonb_build_object('upload_id',id,'page_number',page_number,
  'content_type',content_type,'expires_at',private.api_time(upload_expires_at)) order by page_number) from public.paper_uploads where session_id=s.id));
end $$;

create function public.qiyadat_paper_upload_context(p_actor uuid,p_session_id uuid,p_upload uuid,p_claim uuid default null) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare u public.paper_uploads; at_time timestamptz:=statement_timestamp(); begin
 perform private.paper_session(p_actor,p_session_id,array['awaiting_upload']);perform private.paper_enabled();
 select * into u from public.paper_uploads where id=p_upload and session_id=p_session_id and user_id=p_actor for update;
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 if u.upload_expires_at<=at_time or u.expires_at<=at_time then perform private.api_fail('UPLOAD_EXPIRED'); end if;
 if u.status not in ('prepared','uploaded') then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 if p_claim is not null and u.status='prepared' then
  if u.upload_lease is not null then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
  perform private.api_rate(p_actor,'paper_upload',at_time);
  update public.paper_uploads set upload_lease=p_claim,upload_locked_at=at_time where id=u.id;
 end if;
 return jsonb_build_object('id',u.id,'user_id',u.user_id,'session_id',u.session_id,'object_path',u.object_path,'bucket_id',u.bucket_id,
  'content_type',u.content_type,'size_bytes',u.size_bytes,'sha256',u.sha256,'upload_expires_at',private.api_time(u.upload_expires_at),
  'expires_at',private.api_time(u.expires_at),'status',u.status);
end $$;
create function public.qiyadat_paper_upload_complete(p_actor uuid,p_session_id uuid,p_upload uuid,p_claim uuid,p_success boolean) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare u public.paper_uploads; at_time timestamptz:=statement_timestamp(); begin
 perform private.api_actor(p_actor);perform 1 from public.wat_sessions where id=p_session_id and user_id=p_actor for update;
 select * into u from public.paper_uploads where id=p_upload and user_id=p_actor and session_id=p_session_id for update;
 if not found or u.upload_lease is distinct from p_claim or p_claim is null then return false; end if;
 if p_success then
  perform private.paper_enabled();
  if u.upload_expires_at<=at_time or u.expires_at<=at_time then perform private.api_fail('UPLOAD_EXPIRED'); end if;
  if u.status<>'prepared' or not exists(select 1 from public.wat_sessions where id=p_session_id and status='awaiting_upload') then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
  update public.paper_uploads set status='uploaded',uploaded_at=at_time,upload_lease=null,upload_locked_at=null where id=u.id;
 else
  update public.paper_uploads set status='delete_pending',upload_lease=null,upload_locked_at=null where id=u.id;
 end if;
 return true;
end $$;

create function public.qiyadat_paper_ocr_context(p_actor uuid,p_session_id uuid,p_body jsonb,p_key text) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare s public.wat_sessions; k public.api_idempotency_keys; item jsonb; n integer:=0; identifier uuid; u public.paper_uploads; uploads jsonb:='[]'::jsonb; begin
 perform private.api_actor(p_actor);
 select * into s from public.wat_sessions where id=p_session_id and user_id=p_actor for update;
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 k:=private.api_reserve_key(p_actor,'POST /wat/sessions/'||s.id::text||'/paper/ocr',p_key,p_body);
 if k.response_body is not null then return jsonb_build_object('replay',jsonb_build_object('status',k.response_status,'body',k.response_body)); end if;
 s:=private.paper_session(p_actor,p_session_id,array['awaiting_upload','awaiting_confirmation','failed']);perform private.paper_enabled();
 if s.paper_confirmed_at is not null then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 perform private.api_fields(p_body,array['upload_ids','language'],array['upload_ids','language']);
 perform private.api_choice(p_body,'language',array['en']);
 if jsonb_typeof(p_body->'upload_ids') is distinct from 'array' then perform private.api_fail('PAPER_UPLOAD_INCOMPLETE'); end if;
 if jsonb_array_length(p_body->'upload_ids') not between 1 and 4 or jsonb_array_length(p_body->'upload_ids')<>(select count(*) from public.paper_uploads where session_id=s.id) then
  perform private.api_fail('PAPER_UPLOAD_INCOMPLETE'); end if;
 for item in select value from jsonb_array_elements(p_body->'upload_ids') loop
  n:=n+1;begin identifier:=(item#>>'{}')::uuid;exception when invalid_text_representation then perform private.api_fail('PAPER_UPLOAD_INCOMPLETE');end;
  select * into u from public.paper_uploads where id=identifier and session_id=s.id and user_id=p_actor and page_number=n;
  if not found then perform private.api_fail('PAPER_UPLOAD_INCOMPLETE'); end if;
  if u.expires_at<=statement_timestamp() or u.status in ('delete_pending','deleted') or (u.status='prepared' and u.upload_expires_at<=statement_timestamp()) then perform private.api_fail('UPLOAD_EXPIRED'); end if;
  if u.status<>'uploaded' or u.uploaded_at is null or u.uploaded_at>u.upload_expires_at then perform private.api_fail('PAPER_UPLOAD_INCOMPLETE'); end if;
  uploads:=uploads||jsonb_build_array(to_jsonb(u));
 end loop;
 return jsonb_build_object('uploads',uploads);
end $$;
create function public.qiyadat_paper_request_ocr(p_actor uuid,p_session_id uuid,p_body jsonb,p_key text) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare context jsonb; j public.processing_jobs; item jsonb; k public.api_idempotency_keys; result jsonb;
 at_time timestamptz:=statement_timestamp(); needed integer; identifier uuid; begin
 context:=public.qiyadat_paper_ocr_context(p_actor,p_session_id,p_body,p_key);
 if context ? 'replay' then return context->'replay'; end if;
 perform private.api_rate(p_actor,'paper_ocr',at_time);
 needed:=jsonb_array_length(context->'uploads');
 if not private.paper_cap(at_time,needed,false) then perform private.api_fail('GLOBAL_QUOTA_EXHAUSTED'); end if;
 insert into public.processing_jobs(user_id,session_id,type,max_attempts,created_at,updated_at,next_attempt_at)
 values(p_actor,p_session_id,'ocr',3,at_time,at_time,at_time) returning * into j;
 for item in select value from jsonb_array_elements(context->'uploads') loop
  identifier:=(item->>'id')::uuid;
  insert into public.usage_reservations(user_id,session_id,job_id,type,operation_key,reserved_at)
  values(p_actor,p_session_id,j.id,'ocr_page','ocr:'||j.id::text||':'||identifier::text,at_time);
  insert into private.ocr_job_pages(job_id,upload_id,ordinal,expires_at) values(j.id,identifier,(item->>'page_number')::integer,(item->>'expires_at')::timestamptz);
 end loop;
 update public.wat_sessions set status='ocr_queued' where id=p_session_id;
 result:=jsonb_build_object('status',202,'body',jsonb_build_object('data',jsonb_build_object('job_id',j.id,'session_id',p_session_id,'type','ocr','status','queued','poll_after_ms',2000)));
 k:=private.api_reserve_key(p_actor,'POST /wat/sessions/'||p_session_id::text||'/paper/ocr',p_key,p_body);
 perform private.api_resolve_key(k.id,result);
 return result;
end $$;

create function public.qiyadat_paper_confirm(p_actor uuid,p_session_id uuid,p_body jsonb) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare s public.wat_sessions; item jsonb; n integer; seen integer[]:=array[]::integer[]; value text; at_time timestamptz:=statement_timestamp(); begin
 s:=private.paper_session(p_actor,p_session_id,array['awaiting_confirmation']);
 perform private.api_fields(p_body,array['ocr_revision','responses'],array['ocr_revision','responses']);
 if private.api_integer(p_body,'ocr_revision',1,2147483647)<>s.ocr_revision then perform private.api_fail('OCR_CONFIRMATION_STALE'); end if;
 if jsonb_typeof(p_body->'responses') is distinct from 'array' or jsonb_array_length(p_body->'responses')<>20 then perform private.api_fail('OCR_TEXT_INCOMPLETE'); end if;
 if (select count(*) from public.ocr_drafts where session_id=s.id and ocr_revision=s.ocr_revision and expires_at>at_time)<>20 then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 perform private.api_rate(p_actor,'paper_confirm',at_time);
 for item in select e.value from jsonb_array_elements(p_body->'responses') e loop
  perform private.api_fields(item,array['position','confirmed_text'],array['position','confirmed_text']);
  n:=private.api_integer(item,'position',1,20);
  if n=any(seen) then perform private.api_fail('OCR_TEXT_INCOMPLETE'); end if;seen:=array_append(seen,n);
  value:=normalize(replace(replace(private.api_string(item,'confirmed_text',0,1120),E'\r\n',E'\n'),E'\r',E'\n'),NFC);
  if char_length(value)>280 then perform private.api_fail('VALIDATION_ERROR','confirmed_text','Maximum 280 Unicode code points.'); end if;
  update public.wat_responses set answer=value,status=case when value ~ '[^[:space:]]' then 'answered'::public.response_status else 'blank'::public.response_status end,
   completed=true,locked=true,received_at=at_time where session_id=s.id and position=n and source='ocr_confirmed' and not locked;
  if not found then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 end loop;
 update public.wat_sessions set status='finished',paper_confirmed_at=at_time,eligible_for_feedback=true where id=s.id;
 update public.paper_uploads set status='delete_pending',confirmed_at=at_time where session_id=s.id and status='uploaded';
 delete from public.ocr_drafts where session_id=s.id;
 delete from private.ocr_job_pages where job_id in (select id from public.processing_jobs where session_id=s.id and type='ocr');
 return jsonb_build_object('session_id',s.id,'status','finished','confirmed_at',private.api_time(at_time),
  'images',jsonb_build_object('status','delete_pending','delete_pending',true),'next_action','generate_report');
end $$;
create function public.qiyadat_paper_draft(p_session_id uuid) returns jsonb
language plpgsql security invoker set search_path = '' as $$ declare s public.wat_sessions; result jsonb; begin
 if auth.uid() is null or not private.candidate_can_access(auth.uid()) then raise exception using errcode='P0001',message='AUTH_INVALID'; end if;
 select * into s from public.wat_sessions where id=p_session_id and user_id=auth.uid();
 if not found then raise exception using errcode='P0001',message='NOT_FOUND'; end if;
 if s.status<>'awaiting_confirmation' then raise exception using errcode='P0001',message='SESSION_STATE_CONFLICT'; end if;
 select jsonb_agg(jsonb_build_object('position',d.position,'word',r.word,'ocr_text',d.ocr_text,'confidence',d.confidence,'needs_review',d.needs_review) order by d.position)
 into result from public.ocr_drafts d join public.wat_responses r on r.session_id=d.session_id and r.position=d.position
 where d.session_id=s.id and d.ocr_revision=s.ocr_revision and d.expires_at>statement_timestamp();
 if jsonb_array_length(coalesce(result,'[]'::jsonb))<>20 then raise exception using errcode='P0001',message='OCR_FAILED'; end if;
 return jsonb_build_object('session_id',s.id,'status',s.status,'ocr_revision',s.ocr_revision,'responses',result);
end $$;

do $$ declare f record; begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='private' and p.proname like 'paper_%') or (n.nspname='public' and p.proname like 'qiyadat_paper_%') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
grant execute on function public.qiyadat_paper_draft(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
