begin;
-- Server sessions may retain client elapsed telemetry. Simulation analytics use
-- the authoritative typed receive time; paper confirmation time is not a timer.
create function private.progress_response_ms(p_practice public.practice_mode,p_response public.response_mode,p_trust public.timing_trust,
 p_started timestamptz,p_position integer,p_stored integer,p_client integer,p_received timestamptz) returns integer
language sql immutable security invoker set search_path = '' as $$
 select case when p_practice<>'simulation' then p_stored
  when p_trust<>'server_verified' then null
  when p_response='typing' and p_received is not null then
   least(15000,greatest(0,floor(extract(epoch from (p_received-(p_started+(p_position-1)*interval '15 seconds')))*1000)))::integer
  when p_client is null then p_stored else null end;
$$;
revoke all on function private.progress_response_ms(public.practice_mode,public.response_mode,public.timing_trust,timestamptz,integer,integer,integer,timestamptz) from public,anon;
grant execute on function private.progress_response_ms(public.practice_mode,public.response_mode,public.timing_trust,timestamptz,integer,integer,integer,timestamptz) to authenticated;

do $$ declare definition text; before_text text; replacement text; begin
 definition:=pg_get_functiondef('public.qiyadat_progress(text,text,text,text)'::regprocedure);
 before_text:='s.practice_mode,s.timing_trust';
 if position(before_text in definition)=0 then raise exception 'Unexpected progress session projection';end if;
 definition:=replace(definition,before_text,'s.practice_mode,s.response_mode,s.timing_trust');
 replacement:='private.progress_response_ms(s.practice_mode,s.response_mode,s.timing_trust,s.started_at,r.position,r.time_used_ms,r.client_elapsed_ms,r.received_at)';
 before_text:='sum(r.time_used_ms)';
 if position(before_text in definition)=0 then raise exception 'Unexpected progress timing sum';end if;
 definition:=replace(definition,before_text,'sum('||replacement||')');
 before_text:='count(r.time_used_ms)';
 if position(before_text in definition)=0 then raise exception 'Unexpected progress timing count';end if;
 execute replace(definition,before_text,'count('||replacement||')');
end $$;
notify pgrst,'reload schema';
commit;
