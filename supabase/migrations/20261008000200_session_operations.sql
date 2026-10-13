begin;
create function private.api_start_result(s public.wat_sessions, resumed boolean) returns jsonb
language sql stable set search_path = '' as $$
 select jsonb_build_object('id',s.id,'status',s.status,'resumed',resumed,
  'schema_version',s.schema_version,'kind',s.kind,'practice_mode',s.practice_mode,
  'response_mode',s.response_mode,'started_at',private.api_time(s.started_at),
  'expires_at',private.api_time(coalesce(s.technical_recovery_until,s.expires_at)),
  'rules',private.api_rules(),'items',coalesce((select jsonb_agg(
   jsonb_build_object('position',r.position,'word',r.word,
    'opens_at',case when s.practice_mode='simulation' then private.api_time(s.started_at+(r.position-1)*interval '15 seconds') end,
    'deadline_at',case when s.practice_mode='simulation' then private.api_time(s.started_at+r.position*interval '15 seconds') end)
   || case when resumed then jsonb_build_object('answer',r.answer,'locked',r.locked,
        'completed',r.completed,'time_used_ms',r.time_used_ms) else '{}'::jsonb end
   order by r.position) from public.wat_responses r where r.session_id=s.id),'[]'::jsonb));
$$;
create function private.api_start_session(actor uuid, body jsonb, at_time timestamptz) returns jsonb
language plpgsql set search_path = '' as $$
declare ws public.wat_sets; s public.wat_sessions; set_identifier uuid; access boolean; begin
 perform private.api_fields(body,array['client_session_id','set_id','set_version','kind','practice_mode','response_mode','session_size'],
   array['client_session_id','set_id','set_version','kind','practice_mode','response_mode','session_size']);
 perform private.api_string(body,'client_session_id',1,128);
 perform private.api_modes(body);
 perform private.api_integer(body,'session_size',20,20);
 perform private.api_integer(body,'set_version',1,2147483647);
 begin set_identifier := private.api_string(body,'set_id',36,36)::uuid;
 exception when invalid_text_representation then perform private.api_fail('VALIDATION_ERROR','set_id','Must be a UUID.'); end;
 if not private.api_flag('wat_enabled') then perform private.api_fail('FEATURE_DISABLED'); end if;
 select * into ws from public.wat_sets where kind=(body->>'kind')::public.wat_kind
   and published_at is not null and published_at <= at_time order by published_at desc,version desc,id desc limit 1;
 if not found or ws.id<>set_identifier or ws.version<>(body->>'set_version')::integer then
   perform private.api_fail('CONFIG_VERSION_MISMATCH'); end if;
 perform private.api_beta(actor,at_time);
 access := private.api_has_access(actor,at_time);
 if not access then
   if body->>'kind'<>'diagnostic' then perform private.api_fail('ENTITLEMENT_REQUIRED'); end if;
   select * into s from public.wat_sessions where user_id=actor and is_free_demo for update;
   if found then
     if s.status='in_progress' and coalesce(s.technical_recovery_until,s.expires_at)>at_time then
       return jsonb_build_object('status',200,'body',jsonb_build_object('data',private.api_start_result(s,true)));
     end if;
     perform private.api_fail('DIAGNOSTIC_ALREADY_USED');
   end if;
 end if;
 select * into s from public.wat_sessions where user_id=actor and client_session_id=body->>'client_session_id';
 if found then
   if s.source<>'server' or (s.wat_set_id,s.set_version,s.kind::text,s.practice_mode::text,s.response_mode::text)
     is distinct from (ws.id,ws.version,body->>'kind',body->>'practice_mode',body->>'response_mode') then
     perform private.api_fail('IDEMPOTENCY_CONFLICT'); end if;
   return jsonb_build_object('status',200,'body',jsonb_build_object('data',private.api_start_result(s,s.status='in_progress')));
 end if;
 if exists(select 1 from public.wat_sessions where user_id=actor and status='in_progress') then
   perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 insert into public.wat_sessions(user_id,client_session_id,wat_set_id,set_version,kind,practice_mode,response_mode,
   started_at,expires_at,is_free_demo,eligible_for_feedback)
 values(actor,body->>'client_session_id',ws.id,ws.version,ws.kind,(body->>'practice_mode')::public.practice_mode,
   (body->>'response_mode')::public.response_mode,at_time,at_time+interval '30 minutes',not access,true) returning * into s;
 insert into public.wat_responses(session_id,user_id,position,word,source)
 select s.id,actor,position,word,case when s.response_mode='typing' then 'typed'::public.response_source else 'ocr_confirmed'::public.response_source end
 from public.wat_set_items where wat_set_id=ws.id and version=ws.version order by position;
 return jsonb_build_object('status',201,'body',jsonb_build_object('data',private.api_start_result(s,false)));
end $$;

create function private.api_save_answer(actor uuid, session_identifier uuid, answer_position integer, body jsonb, received timestamptz)
returns jsonb language plpgsql set search_path = '' as $$
declare s public.wat_sessions; r public.wat_responses; value text; elapsed integer; client_time timestamptz; reason public.advance_reason; begin
 perform private.api_fields(body,array['answer','client_elapsed_ms','client_saved_at','advance_reason'],array['answer']);
 if answer_position is null or answer_position not between 1 and 20 then perform private.api_fail('VALIDATION_ERROR','position','Must be 1 to 20.'); end if;
 value:=normalize(replace(replace(private.api_string(body,'answer',0,1120),E'\r\n',E'\n'),E'\r',E'\n'),NFC);
 if char_length(value)>280 then perform private.api_fail('VALIDATION_ERROR','answer','Maximum 280 Unicode code points after normalization.'); end if;
 if body ? 'client_elapsed_ms' then elapsed:=private.api_integer(body,'client_elapsed_ms',0,2147483647); end if;
 if body ? 'client_saved_at' then client_time:=private.api_timestamp(body,'client_saved_at'); end if;
 if body ? 'advance_reason' then reason:=private.api_choice(body,'advance_reason',array['timer','next','session_end','autosave'])::public.advance_reason; end if;
 select * into s from public.wat_sessions where id=session_identifier and user_id=actor for update;
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 if s.response_mode<>'typing' then perform private.api_fail('SESSION_STATE_CONFLICT'); end if;
 if s.status<>'in_progress' then perform private.api_fail('SESSION_ALREADY_FINISHED'); end if;
 if received>=coalesce(s.technical_recovery_until,s.expires_at) then perform private.api_fail('SESSION_EXPIRED'); end if;
 select * into r from public.wat_responses where session_id=s.id and position=answer_position;
 if r.locked then perform private.api_fail('ANSWER_ALREADY_LOCKED'); end if;
 if s.practice_mode='simulation' then
   if received<s.started_at+(answer_position-1)*interval '15 seconds' then perform private.api_fail('ANSWER_NOT_ACTIVE'); end if;
   if received>s.started_at+answer_position*interval '15 seconds'+interval '2 seconds' then perform private.api_fail('SESSION_LATE_ANSWER'); end if;
   elapsed:=coalesce(elapsed,least(15000,greatest(0,floor(extract(epoch from (received-(s.started_at+(answer_position-1)*interval '15 seconds')))*1000)))::integer);
 end if;
 update public.wat_responses set answer=value,completed=true,
   status=case when value ~ '[^[:space:]]' then 'answered'::public.response_status else 'blank'::public.response_status end,
   locked=(s.practice_mode='simulation'),time_used_ms=elapsed,
   client_elapsed_ms=case when body ? 'client_elapsed_ms' then (body->>'client_elapsed_ms')::integer end,
   client_saved_at=client_time,advance_reason=reason,received_at=received
 where session_id=s.id and position=answer_position returning * into r;
 return jsonb_build_object('status',200,'body',jsonb_build_object('data',jsonb_build_object(
   'session_id',s.id,'position',r.position,'saved',true,'locked',r.locked,'answer',r.answer,
   'time_used_ms',r.time_used_ms,'received_at',private.api_time(r.received_at))));
end $$;

create function private.api_statistics(session_identifier uuid) returns jsonb
language sql stable set search_path = '' as $$
 select jsonb_build_object('total_words',20,'completed_words',count(*) filter(where completed),
   'answered_words',count(*) filter(where status='answered'),'blank_words',20-count(*) filter(where status='answered'),
   'average_response_seconds',round(avg(time_used_ms) filter(where completed)/1000.0,1))
 from public.wat_responses where session_id=session_identifier;
$$;
create function private.api_finish_session(actor uuid, session_identifier uuid, body jsonb, at_time timestamptz)
returns jsonb language plpgsql set search_path = '' as $$
declare s public.wat_sessions; reason public.finish_reason; statistics jsonb; begin
 perform private.api_fields(body,array['reason','client_completed_at'],array['reason']);
 reason:=private.api_choice(body,'reason',array['natural','manual'])::public.finish_reason;
 if body ? 'client_completed_at' then perform private.api_timestamp(body,'client_completed_at'); end if;
 select * into s from public.wat_sessions where id=session_identifier and user_id=actor for update;
 if not found then perform private.api_fail('NOT_FOUND'); end if;
 if s.status<>'in_progress' then perform private.api_fail('SESSION_ALREADY_FINISHED'); end if;
 if at_time>=coalesce(s.technical_recovery_until,s.expires_at) then perform private.api_fail('SESSION_EXPIRED'); end if;
 update public.wat_responses set completed=true,status='blank',time_used_ms=case when s.practice_mode='simulation' then 15000 end
 where session_id=s.id and not completed and not locked
   and ((s.practice_mode='simulation' and at_time>=s.started_at+position*interval '15 seconds')
     or (s.response_mode='paper' and s.practice_mode='training' and reason='natural'));
 if s.response_mode='typing' then
   update public.wat_responses set locked=true where session_id=s.id and not locked;
 end if;
 statistics:=private.api_statistics(s.id);
 update public.wat_sessions set status=case when response_mode='typing' then 'finished'::public.session_status else 'awaiting_upload'::public.session_status end,
  finished_at=at_time,finish_reason=reason,ended_early=(statistics->>'completed_words')::integer<20
 where id=s.id returning * into s;
 return jsonb_build_object('status',200,'body',jsonb_build_object('data',jsonb_build_object(
   'id',s.id,'status',s.status,'finished_at',private.api_time(s.finished_at),'ended_early',s.ended_early,
   'next_action',case when s.response_mode='typing' then 'generate_report' else 'upload_paper_pages' end,'statistics',statistics)));
end $$;

create function private.api_import_session(actor uuid, body jsonb, at_time timestamptz) returns jsonb
language plpgsql set search_path = '' as $$
declare ws public.wat_sets; s public.wat_sessions; item jsonb; expected text; value text; started timestamptz;
 completed_at timestamptz; position_value integer; completed_value boolean; count_completed integer:=0;
 has_text boolean:=false; hash_value text; previous_hash text; seen integer[]:='{}'; elapsed integer; begin
 perform private.api_fields(body,
 array['schema_version','client_session_id','source','set_code','set_version','kind','practice_mode','response_mode','started_at','completed_at','ended_early','responses'],
 array['schema_version','client_session_id','source','set_code','set_version','kind','practice_mode','response_mode','started_at','completed_at','ended_early','responses']);
 perform private.api_integer(body,'schema_version',1,1);
 perform private.api_integer(body,'set_version',1,2147483647);
 perform private.api_string(body,'client_session_id',1,128);
 perform private.api_string(body,'set_code',1,80);
 perform private.api_modes(body);
 perform private.api_choice(body,'source',array['guest_local','legacy_local_storage']);
 if jsonb_typeof(body->'ended_early')<>'boolean' then perform private.api_fail('VALIDATION_ERROR','ended_early','Must be a boolean.'); end if;
 started:=private.api_timestamp(body,'started_at'); completed_at:=private.api_timestamp(body,'completed_at');
 if completed_at<started then perform private.api_fail('VALIDATION_ERROR','completed_at','Cannot precede started_at.'); end if;
 if jsonb_typeof(body->'responses') is distinct from 'array' or jsonb_array_length(body->'responses')<>20 then
   perform private.api_fail('VALIDATION_ERROR','responses','Exactly 20 positions are required.'); end if;
 select * into ws from public.wat_sets where code=body->>'set_code' and version=(body->>'set_version')::integer
   and kind=(body->>'kind')::public.wat_kind and published_at is not null;
 if not found then perform private.api_fail('CONFIG_VERSION_MISMATCH'); end if;
 for item in select * from jsonb_array_elements(body->'responses') loop
   perform private.api_fields(item,array['position','word','answer','completed','time_used_ms'],array['position','word','answer','completed','time_used_ms']);
   position_value:=private.api_integer(item,'position',1,20);
   if position_value=any(seen) then perform private.api_fail('VALIDATION_ERROR','responses','Positions must be unique.'); end if;
   seen:=array_append(seen,position_value);
   select word into expected from public.wat_set_items where wat_set_id=ws.id and version=ws.version and position=position_value;
   if private.api_string(item,'word',1,80)<>expected then perform private.api_fail('CONFIG_VERSION_MISMATCH'); end if;
   value:=normalize(replace(replace(private.api_string(item,'answer',0,1120),E'\r\n',E'\n'),E'\r',E'\n'),NFC);
   if char_length(value)>280 then perform private.api_fail('VALIDATION_ERROR','responses','Answer exceeds 280 code points.'); end if;
   if jsonb_typeof(item->'completed')<>'boolean' then perform private.api_fail('VALIDATION_ERROR','responses','completed must be boolean.'); end if;
   completed_value:=(item->>'completed')::boolean;
   perform private.api_integer(item,'time_used_ms',0,2147483647);
   if not completed_value and value<>'' then perform private.api_fail('VALIDATION_ERROR','responses','Unattempted positions cannot contain an answer.'); end if;
   if completed_value then count_completed:=count_completed+1; end if;
   has_text:=has_text or value ~ '[^[:space:]]';
 end loop;
 hash_value:=encode(extensions.digest(body::text,'sha256'),'hex');
 select * into s from public.wat_sessions where user_id=actor and client_session_id=body->>'client_session_id';
 if found then
   select request_hash into previous_hash from public.legacy_imports where session_id=s.id and user_id=actor;
   if previous_hash is distinct from hash_value then perform private.api_fail('IDEMPOTENCY_CONFLICT'); end if;
   return jsonb_build_object('status',200,'body',jsonb_build_object('data',jsonb_build_object(
     'id',s.id,'status',s.status,'source',s.source,'timing_trust',s.timing_trust,
     'eligible_for_feedback',s.eligible_for_feedback,'imported_at',private.api_time(s.imported_at))));
 end if;
 perform private.api_beta(actor,at_time);
 insert into public.wat_sessions(user_id,client_session_id,wat_set_id,set_version,kind,practice_mode,response_mode,
  status,source,timing_trust,started_at,expires_at,finished_at,finish_reason,ended_early,eligible_for_feedback,imported_at)
 values(actor,body->>'client_session_id',ws.id,ws.version,ws.kind,(body->>'practice_mode')::public.practice_mode,
  (body->>'response_mode')::public.response_mode,'finished',(body->>'source')::public.session_source,'client_reported',
  started,started+interval '30 minutes',completed_at,case when (body->>'ended_early')::boolean then 'manual'::public.finish_reason else 'natural'::public.finish_reason end,
  (body->>'ended_early')::boolean or count_completed<20,
  private.api_has_access(actor,at_time) and (body->>'response_mode'='typing' or has_text),at_time) returning * into s;
 for item in select * from jsonb_array_elements(body->'responses') loop
   value:=normalize(replace(replace(item->>'answer',E'\r\n',E'\n'),E'\r',E'\n'),NFC);
   completed_value:=(item->>'completed')::boolean;
   elapsed:=(item->>'time_used_ms')::integer;
   insert into public.wat_responses(session_id,user_id,position,word,answer,source,status,completed,locked,time_used_ms)
   values(s.id,actor,(item->>'position')::integer,item->>'word',value,
     case when s.response_mode='paper' then 'ocr_confirmed'::public.response_source
       when s.source='legacy_local_storage' then 'legacy_typed'::public.response_source else 'typed'::public.response_source end,
     case when not completed_value then 'not_attempted'::public.response_status
       when value ~ '[^[:space:]]' then 'answered'::public.response_status else 'blank'::public.response_status end,
     completed_value,true,elapsed);
 end loop;
 insert into public.legacy_imports(user_id,session_id,client_session_id,source,request_hash,imported_at)
 values(actor,s.id,s.client_session_id,s.source,hash_value,at_time);
 return jsonb_build_object('status',201,'body',jsonb_build_object('data',jsonb_build_object(
   'id',s.id,'status',s.status,'source',s.source,'timing_trust',s.timing_trust,
   'eligible_for_feedback',s.eligible_for_feedback,'imported_at',private.api_time(s.imported_at))));
end $$;

create function private.api_patch_profile(actor uuid, body jsonb) returns jsonb
language plpgsql set search_path = '' as $$ declare version text; display text; zone text; begin
 perform private.api_fields(body,array['display_name','timezone','accept_ai_processing_terms_version'],array[]::text[]);
 if body='{}'::jsonb then perform private.api_fail('VALIDATION_ERROR','body','At least one field is required.'); end if;
 if body ? 'display_name' then
   display:=regexp_replace(private.api_string(body,'display_name',1,10000),'^\s+|\s+$','','g');
   if char_length(display) not between 1 and 80 then perform private.api_fail('VALIDATION_ERROR','display_name','Must be 1 to 80 trimmed characters.'); end if;
 end if;
 if body ? 'timezone' then
   zone:=private.api_string(body,'timezone',1,100);
   if not exists(select 1 from pg_catalog.pg_timezone_names where name=zone and name not like 'posix/%' and name not like 'right/%' and name<>'localtime')
   then perform private.api_fail('VALIDATION_ERROR','timezone','Must be an IANA timezone.'); end if;
 end if;
 if body ? 'accept_ai_processing_terms_version' then
   version:=private.api_string(body,'accept_ai_processing_terms_version',1,80);
   if version is distinct from (select value#>>'{}' from public.app_settings where key='ai_processing_terms_version') then
     perform private.api_fail('VALIDATION_ERROR','accept_ai_processing_terms_version','Only the current terms can be accepted.'); end if;
 end if;
 update public.profiles set display_name=case when body ? 'display_name' then display else display_name end,
   timezone=case when body ? 'timezone' then zone else timezone end where id=actor;
 if version is not null and not exists(select 1 from public.profile_consents where user_id=actor and terms_version=version and accepted) then
   insert into public.profile_consents(user_id,terms_version,accepted) values(actor,version,true);
 end if;
 return jsonb_build_object('status',200,'body',jsonb_build_object('data',jsonb_build_object('id',actor)));
end $$;

-- Helpers are private; browsers cannot invoke them or supply a clock to the API.
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and p.proname like 'api_%' loop
   execute format('revoke all on function %s from public, anon, authenticated',f.signature);
   execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
commit;
