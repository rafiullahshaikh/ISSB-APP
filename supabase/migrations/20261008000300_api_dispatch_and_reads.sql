begin;
-- Only the isolated server client may call mutations. actor comes from Auth.getUser,
-- never from request JSON. statement_timestamp captures receive time before locks.
create function public.qiyadat_mutate(p_actor uuid,p_operation text,p_body jsonb,
 p_key text default null,p_session_id uuid default null,p_position integer default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare at_time timestamptz:=statement_timestamp(); key_record public.api_idempotency_keys; route_name text; result jsonb; begin
 perform private.api_actor(p_actor);
 if p_operation not in ('start','answer','finish','import','profile') or p_operation is null then perform private.api_fail('INVALID_REQUEST'); end if;
 if p_operation in ('start','finish','import') then
   route_name:=case p_operation when 'start' then 'POST /wat/sessions'
     when 'import' then 'POST /wat/sessions/import' else 'POST /wat/sessions/'||p_session_id::text||'/finish' end;
   if route_name is null then perform private.api_fail('NOT_FOUND'); end if;
   key_record:=private.api_reserve_key(p_actor,route_name,p_key,p_body);
   if key_record.response_body is not null then
     return jsonb_build_object('status',key_record.response_status,'body',key_record.response_body); end if;
 end if;
 perform private.api_rate(p_actor,p_operation,at_time);
 case p_operation
   when 'start' then result:=private.api_start_session(p_actor,p_body,at_time);
   when 'answer' then result:=private.api_save_answer(p_actor,p_session_id,p_position,p_body,at_time);
   when 'finish' then result:=private.api_finish_session(p_actor,p_session_id,p_body,at_time);
   when 'import' then result:=private.api_import_session(p_actor,p_body,at_time);
   when 'profile' then result:=private.api_patch_profile(p_actor,p_body);
 end case;
 if key_record.id is not null then perform private.api_resolve_key(key_record.id,result); end if;
 return result;
end $$;

create function public.qiyadat_health() returns boolean
language plpgsql security invoker set search_path = '' as $$ begin
 perform private.api_assert_service();
 return exists(select 1 from public.app_settings where key='API_VERSION');
end $$;
create function public.qiyadat_public_config(p_kind text) returns jsonb
language plpgsql security invoker set search_path = '' as $$ declare ws public.wat_sets; begin
 perform private.api_assert_service();
 if p_kind is null or p_kind not in ('diagnostic','practice') then perform private.api_fail('INVALID_REQUEST'); end if;
 if not private.api_flag('wat_enabled') then perform private.api_fail('FEATURE_DISABLED'); end if;
 select * into ws from public.wat_sets where kind=p_kind::public.wat_kind
 and published_at is not null and published_at<=statement_timestamp()
 order by published_at desc,version desc,id desc limit 1;
 if not found then perform private.api_fail('FEATURE_DISABLED'); end if;
 return jsonb_build_object('schema_version',ws.schema_version,
  'set',jsonb_build_object('id',ws.id,'code',ws.code,'version',ws.version,'kind',ws.kind),
  'rules',private.api_rules(),
  'free_demo',jsonb_build_object('requires_authentication',true,'lifetime_sessions_per_account',1,'includes_reports',1),
  'words',(select jsonb_agg(jsonb_build_object('position',position,'word',word) order by position)
    from public.wat_set_items where wat_set_id=ws.id and version=ws.version));
end $$;
create function public.qiyadat_admin_check(p_actor uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$ begin
 perform private.api_assert_service(); return private.is_active_admin(p_actor);
end $$;
create function public.qiyadat_account_context(p_actor uuid) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare at_time timestamptz:=statement_timestamp(); e public.entitlements; demo public.wat_sessions;
 terms text; consent public.profile_consents; used integer; free_used integer; release_at timestamptz;
 has_access boolean; demo_state text; report_state text; technical boolean; begin
 perform private.api_actor(p_actor);
 perform private.api_beta(p_actor,at_time);
 has_access:=private.api_has_access(p_actor,at_time);
 select * into e from public.entitlements where user_id=p_actor and type in ('founding_30d','beta')
 order by (status='active' and starts_at<=at_time and (expires_at is null or expires_at>at_time)) desc,
   (type='founding_30d') desc,starts_at desc,id desc limit 1;
 select * into demo from public.wat_sessions where user_id=p_actor and is_free_demo;
 select value#>>'{}' into terms from public.app_settings where key='ai_processing_terms_version';
 select * into consent from public.profile_consents where user_id=p_actor order by accepted_at desc,id desc limit 1;
 select count(*)::integer,min(reserved_at)+interval '24 hours' into used,release_at
 from public.usage_reservations where user_id=p_actor and type in ('report','diagnostic_report')
  and status in ('reserved','consumed') and reserved_at>at_time-interval '24 hours';
 select count(*)::integer into free_used from public.usage_reservations where user_id=p_actor
  and type='diagnostic_report' and status in ('reserved','consumed');
 if demo.id is not null then
   if exists(select 1 from public.feedback_reports where session_id=demo.id) then
     report_state:='ready'; free_used:=1;
   else select status::text into report_state from public.processing_jobs where session_id=demo.id and type='feedback'
       order by created_at desc,id desc limit 1;
   end if;
 end if;
 technical:=demo.id is not null and demo.status='failed' and demo.technical_failure_verified_at is not null;
 demo_state:=case when demo.id is null then 'available' when technical then 'technical_failure'
   when demo.status='in_progress' and coalesce(demo.technical_recovery_until,demo.expires_at)>at_time then 'in_progress' else 'completed' end;
 return jsonb_build_object(
  'role',case when private.is_active_admin(p_actor) then 'admin' else 'candidate' end,
  'ai_processing_consent',jsonb_build_object('accepted',coalesce(consent.accepted and consent.terms_version=terms,false),
    'version',terms,'accepted_at',case when consent.accepted and consent.terms_version=terms then private.api_time(consent.accepted_at) end),
  'entitlement',case when e.id is null then null else jsonb_build_object('type',e.type,
    'status',case when e.status='active' and e.expires_at<=at_time then 'expired' else e.status::text end,
    'starts_at',private.api_time(e.starts_at),'expires_at',private.api_time(e.expires_at)) end,
  'free_demo',jsonb_build_object('status',demo_state,'session_id',demo.id,'report_status',report_state,
    'can_start',demo.id is null,'can_resume',demo_state='in_progress','can_retry_technical_failure',technical),
  'usage',jsonb_build_object('free_demo_sessions_used_lifetime',case when demo.id is null then 0 else 1 end,
    'free_demo_sessions_remaining_lifetime',case when demo.id is null then 1 else 0 end,
    'free_reports_used_lifetime',least(free_used,1),'free_reports_remaining_lifetime',greatest(0,1-free_used),
    'reports_used_rolling_24h',used,'reports_remaining_rolling_24h',case when has_access then greatest(0,3-used) else 0 end,
    'next_slot_releases_at',case when has_access and used>=3 then private.api_time(release_at) end),
  'features',jsonb_build_object('ocr_enabled',private.api_flag('ocr_enabled'),'feedback_enabled',private.api_flag('feedback_enabled'),
    'payments_enabled',private.api_flag('payments_enabled'),'beta_open',private.api_flag('beta_open')));
end $$;

-- Candidate history executes with the user JWT and RLS; there is no actor argument.
create function public.qiyadat_history(p_filters jsonb default '{}'::jsonb,p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare rows jsonb; items jsonb; more boolean; next_position jsonb; field text; begin
 if auth.uid() is null or not private.candidate_can_access(auth.uid()) then
   raise exception using errcode='P0001',message='AUTH_INVALID'; end if;
 if p_limit is null or p_limit not between 1 and 100 or jsonb_typeof(p_filters) is distinct from 'object'
   or exists(select 1 from jsonb_object_keys(p_filters) k where k not in ('kind','practice_mode','response_mode','status','from','to'))
   or (p_filters ? 'kind' and coalesce(p_filters->>'kind','') not in ('diagnostic','practice'))
   or (p_filters ? 'practice_mode' and coalesce(p_filters->>'practice_mode','') not in ('training','simulation'))
   or (p_filters ? 'response_mode' and coalesce(p_filters->>'response_mode','') not in ('typing','paper'))
   or (p_filters ? 'status' and coalesce(p_filters->>'status','') not in ('in_progress','finished','awaiting_upload','ocr_processing','awaiting_confirmation','feedback_processing','ready','failed'))
 then raise exception using errcode='P0001',message='VALIDATION_ERROR'; end if;
 if p_cursor is not null and (jsonb_typeof(p_cursor) is distinct from 'object' or not p_cursor ?& array['at','id']
   or exists(select 1 from jsonb_object_keys(p_cursor) k where k not in ('at','id'))) then
   raise exception using errcode='P0001',message='VALIDATION_ERROR'; end if;
 foreach field in array array['from','to'] loop
   if p_filters ? field and (jsonb_typeof(p_filters->field) is distinct from 'string'
     or p_filters->>field !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$'
     or not isfinite((p_filters->>field)::timestamptz)) then
     raise exception using errcode='P0001',message='VALIDATION_ERROR'; end if;
 end loop;
 if p_filters ?& array['from','to'] and (p_filters->>'from')::timestamptz>(p_filters->>'to')::timestamptz then
   raise exception using errcode='P0001',message='VALIDATION_ERROR'; end if;
 if p_cursor is not null and (jsonb_typeof(p_cursor->'at') is distinct from 'string'
   or jsonb_typeof(p_cursor->'id') is distinct from 'string'
   or p_cursor->>'at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$'
   or not isfinite((p_cursor->>'at')::timestamptz)
   or (p_cursor->>'id')::uuid is null) then
   raise exception using errcode='P0001',message='VALIDATION_ERROR'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q._cursor_at desc,q.id desc),'[]'::jsonb) into rows from (
   select s.id,s.kind,s.status,s.practice_mode,s.response_mode,
    to_char(s.started_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as started_at,
    to_char(s.finished_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as finished_at,
    (select count(*) from public.wat_responses r where r.session_id=s.id and r.completed) as completed_words,
    (select count(*) from public.wat_responses r where r.session_id=s.id and r.status='answered') as answered_words,
    (select round(count(*) filter(where r.completed)*100.0/20,1) from public.wat_responses r where r.session_id=s.id) as completion_percent,
    (select round(avg(r.time_used_ms) filter(where r.completed)/1000.0,1) from public.wat_responses r where r.session_id=s.id) as average_response_seconds,
    (select overall_score from public.feedback_reports f where f.session_id=s.id order by f.generated_at desc,f.id desc limit 1) as report_score,
    to_char(s.created_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as _cursor_at
   from public.wat_sessions s where s.user_id=auth.uid()
    and (not p_filters ? 'kind' or s.kind::text=p_filters->>'kind')
    and (not p_filters ? 'practice_mode' or s.practice_mode::text=p_filters->>'practice_mode')
    and (not p_filters ? 'response_mode' or s.response_mode::text=p_filters->>'response_mode')
    and (not p_filters ? 'status' or s.status::text=p_filters->>'status')
    and (not p_filters ? 'from' or s.started_at>=(p_filters->>'from')::timestamptz)
    and (not p_filters ? 'to' or s.started_at<=(p_filters->>'to')::timestamptz)
    and (p_cursor is null or (s.created_at,s.id)<((p_cursor->>'at')::timestamptz,(p_cursor->>'id')::uuid))
   order by s.created_at desc,s.id desc limit p_limit+1
 ) q;
 more:=jsonb_array_length(rows)>p_limit;
 select coalesce(jsonb_agg(value-'_cursor_at' order by ordinality),'[]'::jsonb) into items
 from jsonb_array_elements(rows) with ordinality where ordinality<=p_limit;
 if more then next_position:=jsonb_build_object('at',rows->(p_limit-1)->>'_cursor_at','id',rows->(p_limit-1)->>'id'); end if;
 return jsonb_build_object('items',items,'has_more',more,'next',next_position);
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
 raise exception using errcode='P0001',message='VALIDATION_ERROR';
end $$;

revoke all on function public.qiyadat_mutate(uuid,text,jsonb,text,uuid,integer) from public,anon,authenticated;
revoke all on function public.qiyadat_health() from public,anon,authenticated;
revoke all on function public.qiyadat_public_config(text) from public,anon,authenticated;
revoke all on function public.qiyadat_admin_check(uuid) from public,anon,authenticated;
revoke all on function public.qiyadat_account_context(uuid) from public,anon,authenticated;
revoke all on function public.qiyadat_history(jsonb,jsonb,integer) from public,anon;
grant execute on function public.qiyadat_mutate(uuid,text,jsonb,text,uuid,integer) to service_role;
grant execute on function public.qiyadat_health() to service_role;
grant execute on function public.qiyadat_public_config(text) to service_role;
grant execute on function public.qiyadat_admin_check(uuid) to service_role;
grant execute on function public.qiyadat_account_context(uuid) to service_role;
grant execute on function public.qiyadat_history(jsonb,jsonb,integer) to authenticated;
notify pgrst,'reload schema';
commit;
