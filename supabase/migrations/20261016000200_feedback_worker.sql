begin;
create function private.feedback_fail(job_identifier uuid,worker uuid,code text,retryable boolean,at_time timestamptz)
returns boolean language plpgsql set search_path = '' as $$
declare j public.processing_jobs; begin
 select * into j from public.processing_jobs where id=job_identifier for update;
 if not found or j.type<>'feedback' or j.status<>'processing' or j.locked_by is distinct from worker then return false; end if;
 if code is null or code not in ('AI_OUTPUT_INVALID','PROVIDER_UNAVAILABLE','INTERNAL_ERROR','AI_CONSENT_REQUIRED',
 'FEATURE_DISABLED','GLOBAL_QUOTA_EXHAUSTED','ENTITLEMENT_REQUIRED','AUTH_INVALID') then code:='INTERNAL_ERROR'; end if;
 if retryable and code in ('AI_OUTPUT_INVALID','PROVIDER_UNAVAILABLE','INTERNAL_ERROR') and j.attempt<j.max_attempts then
  update public.processing_jobs set status='retrying',locked_at=null,locked_by=null,error_code=code,
   next_attempt_at=at_time+least(60,5*power(2,greatest(0,j.attempt-1))) * interval '1 second' where id=j.id;
  update public.wat_sessions set status='feedback_queued' where id=j.session_id;
 else
  update public.processing_jobs set status='failed',locked_at=null,locked_by=null,error_code=code,completed_at=at_time where id=j.id;
  update public.usage_reservations set status='released',released_at=at_time where job_id=j.id and status='reserved';
  update public.wat_sessions set status='failed',technical_failure_verified_at=at_time where id=j.session_id;
 end if;
 return true;
end $$;

create function public.qiyadat_feedback_claim(p_worker uuid,p_model text,p_prompt text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare candidate public.processing_jobs; j public.processing_jobs; at_time timestamptz:=statement_timestamp(); begin
 perform private.api_assert_service();
 if p_worker is null or p_model is null or p_model !~ '^[a-zA-Z0-9._-]{1,120}$'
  or p_prompt is null or p_prompt !~ '^[a-zA-Z0-9._-]{1,80}$' then perform private.api_fail('VALIDATION_ERROR'); end if;
 for candidate in select * from public.processing_jobs where type='feedback' and status in ('queued','retrying')
  and next_attempt_at<=at_time order by next_attempt_at,created_at,id limit 20 loop
  -- Global lock order is profile -> session -> job -> reservation -> provider cap.
  perform 1 from public.profiles where id=candidate.user_id for update skip locked;
  if not found then continue; end if;
  perform 1 from public.wat_sessions where id=candidate.session_id for update;
  select * into j from public.processing_jobs where id=candidate.id for update skip locked;
  if not found or j.status not in ('queued','retrying') or j.next_attempt_at>at_time then continue; end if;
  update public.processing_jobs set status='processing',attempt=attempt+1,started_at=coalesce(started_at,at_time),
   locked_at=at_time,locked_by=p_worker,model_name=coalesce(model_name,p_model),prompt_version=coalesce(prompt_version,p_prompt)
   where id=j.id returning * into j;
  update public.wat_sessions set status='feedback_processing' where id=j.session_id;
  if exists(select 1 from public.profiles where id=j.user_id and access_disabled_at is not null) then
   perform private.feedback_fail(j.id,p_worker,'AUTH_INVALID',false,at_time); continue; end if;
  if not private.api_flag('feedback_enabled') then
   perform private.feedback_fail(j.id,p_worker,'FEATURE_DISABLED',false,at_time); continue; end if;
  if not private.feedback_consent(j.user_id) then
   perform private.feedback_fail(j.id,p_worker,'AI_CONSENT_REQUIRED',false,at_time); continue; end if;
  if not private.feedback_cap(at_time,true) then
   perform private.feedback_fail(j.id,p_worker,'GLOBAL_QUOTA_EXHAUSTED',false,at_time); continue; end if;
  return jsonb_build_object('id',j.id,'worker',p_worker,'request_id',j.request_id,'attempt',j.attempt,
   'model',j.model_name,'prompt_version',j.prompt_version,'rubric_version',j.rubric_version,
   'responses',(select jsonb_agg(jsonb_build_object('position',position,'word',word,'answer',answer,'status',status) order by position)
    from public.wat_responses where session_id=j.session_id));
 end loop;
 return null;
end $$;

create function public.qiyadat_feedback_authorize(p_job uuid,p_worker uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare j public.processing_jobs; begin
 perform private.api_assert_service();
 select * into j from public.processing_jobs where id=p_job and type='feedback' and status='processing' and locked_by=p_worker;
 return found and j.locked_at>statement_timestamp()-interval '5 minutes' and private.api_flag('feedback_enabled')
  and private.feedback_consent(j.user_id) and exists(select 1 from public.profiles where id=j.user_id and access_disabled_at is null);
end $$;

create function public.qiyadat_feedback_fail(p_job uuid,p_worker uuid,p_code text,p_retryable boolean)
returns boolean language plpgsql security invoker set search_path = '' as $$
declare j public.processing_jobs; begin
 perform private.api_assert_service();
 select * into j from public.processing_jobs where id=p_job and type='feedback';
 if not found then return false; end if;
 perform 1 from public.profiles where id=j.user_id for update;
 perform 1 from public.wat_sessions where id=j.session_id for update;
 return private.feedback_fail(p_job,p_worker,p_code,coalesce(p_retryable,false),statement_timestamp());
end $$;

create function private.feedback_recover(at_time timestamptz) returns integer
language plpgsql set search_path = '' as $$
declare candidate public.processing_jobs; j public.processing_jobs; recovered integer:=0; begin
 for candidate in select * from public.processing_jobs where type='feedback' and status='processing'
  and locked_at<=at_time-interval '5 minutes' order by locked_at,id limit 20 loop
  perform 1 from public.profiles where id=candidate.user_id for update skip locked;
  if not found then continue; end if;
  perform 1 from public.wat_sessions where id=candidate.session_id for update;
  select * into j from public.processing_jobs where id=candidate.id for update skip locked;
  if found and j.status='processing' and j.locked_at<=at_time-interval '5 minutes' then
   perform private.feedback_fail(j.id,j.locked_by,'PROVIDER_UNAVAILABLE',true,at_time);
   recovered:=recovered+1;
  end if;
 end loop;
 return recovered;
end $$;
create function public.qiyadat_feedback_recover() returns integer
language plpgsql security invoker set search_path = '' as $$ begin
 perform private.api_assert_service();return private.feedback_recover(statement_timestamp());
end $$;

create function private.feedback_validate(output jsonb,session_identifier uuid) returns void
language plpgsql set search_path = '' as $$
declare item jsonb; r public.wat_responses; dimension text; label text; entry jsonb; summary jsonb;
 n integer:=0; evidence jsonb; begin
 perform private.api_fields(output,array['sentences','summary'],array['sentences','summary']);
 if jsonb_typeof(output->'sentences') is distinct from 'array' or jsonb_array_length(output->'sentences')<>20 then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
 for item in select value from jsonb_array_elements(output->'sentences') loop
  n:=n+1;
  perform private.api_fields(item,array['position','status','tone_rating','tone_label','tone_note','agency_rating','agency_label','agency_note',
   'clarity_rating','clarity_label','clarity_note','realism_rating','realism_label','realism_note','strength','feedback','safety_flags'],
   array['position','status','feedback','safety_flags']);
  if private.api_integer(item,'position',1,20)<>n then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
  select * into r from public.wat_responses where session_id=session_identifier and position=n;
  if not found then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
  if r.status='answered' then
   if item->>'status' is distinct from 'scored' then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
   perform private.api_string(item,'strength',1,1000);
   foreach dimension in array array['tone','agency','clarity','realism'] loop
    perform private.api_integer(item,dimension||'_rating',1,5);
    label:=private.api_string(item,dimension||'_label',1,40);
    if not label=any(case dimension when 'tone' then array['discouraging','negative','neutral','constructive','balanced']
     when 'agency' then array['passive','limited','developing','active','purposeful']
     when 'clarity' then array['unclear','fragmented','understandable','clear','precise']
     else array['implausible','exaggerated','plausible','grounded','practical'] end) then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
    perform private.api_string(item,dimension||'_note',1,500);
   end loop;
  else
   if item->>'status' is distinct from 'not_scored' or item->'strength' is distinct from 'null'::jsonb
    or item->>'feedback' is distinct from 'No response was recorded.' then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
   foreach dimension in array array['tone','agency','clarity','realism'] loop
    if item->(dimension||'_rating') is distinct from 'null'::jsonb or item->(dimension||'_label') is distinct from 'null'::jsonb
     or item->(dimension||'_note') is distinct from 'null'::jsonb then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
   end loop;
  end if;
  perform private.api_string(item,'feedback',1,2000);
  if jsonb_typeof(item->'safety_flags') is distinct from 'array' or jsonb_array_length(item->'safety_flags')>3
   or exists(select 1 from jsonb_array_elements(item->'safety_flags') f where jsonb_typeof(f)<>'string' or f#>>'{}' not in ('self_harm','violence','other_sensitive'))
   or (r.status<>'answered' and item->'safety_flags'<>'[]'::jsonb) then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
 end loop;
 summary:=output->'summary';
 perform private.api_fields(summary,array['narrative','strengths','weak_areas','next_drill'],array['narrative','strengths','weak_areas','next_drill']);
 perform private.api_string(summary,'narrative',1,4000);
 foreach dimension in array array['strengths','weak_areas'] loop
  if jsonb_typeof(summary->dimension) is distinct from 'array' or jsonb_array_length(summary->dimension)>5 then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
  for entry in select value from jsonb_array_elements(summary->dimension) loop
   perform private.api_fields(entry,case when dimension='strengths' then array['code','label','evidence_positions'] else array['code','label','evidence_positions','recommendation'] end,
    case when dimension='strengths' then array['code','label','evidence_positions'] else array['code','label','evidence_positions','recommendation'] end);
   perform private.api_choice(entry,'code',case when dimension='strengths' then array['CLEAR_EXPRESSION','CONSTRUCTIVE_FRAMING','ACTIVE_RESPONSE','PRACTICAL_FRAMING']
    else array['LOW_SPECIFICITY','LOW_CLARITY','LOW_AGENCY','LOW_REALISM','NEGATIVE_FRAMING'] end);
   perform private.api_string(entry,'label',1,160);
   if dimension='weak_areas' then perform private.api_string(entry,'recommendation',1,1000); end if;
   if jsonb_typeof(entry->'evidence_positions') is distinct from 'array' or jsonb_array_length(entry->'evidence_positions') not between 1 and 20 then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
   for evidence in select value from jsonb_array_elements(entry->'evidence_positions') loop
    if jsonb_typeof(evidence)<>'number' or not exists(select 1 from public.wat_responses
     where session_id=session_identifier and position::text=evidence#>>'{}' and status='answered') then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
   end loop;
  end loop;
 end loop;
 entry:=summary->'next_drill';
 perform private.api_fields(entry,array['code','title','instructions','recommended_items'],array['code','title','instructions','recommended_items']);
 perform private.api_choice(entry,'code',array['ACTOR_ACTION_DRILL','CLARITY_DRILL','PRACTICAL_RESPONSE_DRILL']);
 perform private.api_string(entry,'title',1,160);perform private.api_string(entry,'instructions',1,1000);
 perform private.api_integer(entry,'recommended_items',1,20);
exception when sqlstate 'P0001' or invalid_text_representation or numeric_value_out_of_range then
 perform private.api_fail('AI_OUTPUT_INVALID');
end $$;

create function public.qiyadat_feedback_complete(p_job uuid,p_worker uuid,p_output jsonb,p_model_version text)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare j public.processing_jobs; identifier uuid; item jsonb; notes jsonb; dimension text; at_time timestamptz:=statement_timestamp(); begin
 perform private.api_assert_service();
 select * into j from public.processing_jobs where id=p_job and type='feedback';
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 perform 1 from public.profiles where id=j.user_id for update;
 perform 1 from public.wat_sessions where id=j.session_id for update;
 select * into j from public.processing_jobs where id=p_job for update;
 if j.status='succeeded' and j.locked_by is null then
  select id into identifier from public.feedback_reports where job_id=j.id;return identifier; end if;
 if j.status<>'processing' or j.locked_by is distinct from p_worker or j.locked_at<=at_time-interval '5 minutes' then
  perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 perform private.feedback_validate(p_output,j.session_id);
 if p_model_version is null or p_model_version !~ '^[a-zA-Z0-9._-]{1,120}$' then perform private.api_fail('AI_OUTPUT_INVALID'); end if;
 insert into public.feedback_reports(user_id,session_id,job_id,rubric_version,prompt_version,model_provider,model_name,
  model_version,provider_version,narrative,summary,generated_at)
 values(j.user_id,j.session_id,j.id,j.rubric_version,j.prompt_version,'google_gemini',j.model_name,
  p_model_version,'v1beta',p_output#>>'{summary,narrative}',p_output->'summary',at_time) returning id into identifier;
 for item in select value from jsonb_array_elements(p_output->'sentences') loop
  notes:=null;
  if item->>'status'='scored' then
   notes:='{}'::jsonb;
   foreach dimension in array array['tone','agency','clarity','realism'] loop
    notes:=notes||jsonb_build_object(dimension,jsonb_build_object('label',item->>(dimension||'_label'),'note',item->>(dimension||'_note')));
   end loop;
  end if;
  insert into public.feedback_items(report_id,user_id,session_id,position,status,tone_rating,agency_rating,clarity_rating,realism_rating,
   strength,feedback,rating_notes,safety_flags)
  values(identifier,j.user_id,j.session_id,(item->>'position')::integer,(item->>'status')::public.feedback_status,
   (item->>'tone_rating')::integer,(item->>'agency_rating')::integer,(item->>'clarity_rating')::integer,(item->>'realism_rating')::integer,
   item->>'strength',item->>'feedback',notes,array(select jsonb_array_elements_text(item->'safety_flags'))::public.safety_flag[]);
 end loop;
 update public.feedback_reports set overall_score=a.overall,tone_score=a.tone,agency_score=a.agency,clarity_score=a.clarity,realism_score=a.realism
 from (select round(avg(score),1) overall,round(avg(tone_rating)*2,1) tone,round(avg(agency_rating)*2,1) agency,
  round(avg(clarity_rating)*2,1) clarity,round(avg(realism_rating)*2,1) realism from public.feedback_items where report_id=identifier and status='scored') a
 where id=identifier;
 update public.processing_jobs set status='succeeded',completed_at=at_time,locked_at=null,locked_by=null,error_code=null where id=j.id;
 update public.usage_reservations set status='consumed',consumed_at=at_time where job_id=j.id and status='reserved';
 if not found then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 update public.wat_sessions set status='ready' where id=j.session_id;
 return identifier;
end $$;

do $$ declare f record; begin
 for f in select p.oid::regprocedure signature from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='private' and p.proname like 'feedback_%') or (n.nspname='public' and p.proname like 'qiyadat_feedback_%') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
