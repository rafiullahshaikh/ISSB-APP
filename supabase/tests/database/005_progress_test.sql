begin;
set local search_path=public,extensions;
select no_plan();
create or replace function private.progress_clock() returns timestamptz language sql stable security invoker set search_path = '' as $$select '2026-03-10T10:00:00Z'::timestamptz$$;
create function pg_temp.actor(n integer) returns uuid language sql immutable as $$select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid$$;
create function pg_temp.failure(statement text) returns text language plpgsql as $$begin execute statement;return 'OK';exception when others then return case when sqlstate='P0001' then sqlerrm else sqlstate end;end$$;
create temp table cases(name text primary key,value jsonb);
grant all on cases to authenticated;
create function pg_temp.put(name text,value jsonb) returns void language sql as $$insert into cases values(name,value) on conflict(name) do update set value=excluded.value$$;
create function pg_temp.get(name text) returns jsonb language sql stable as $$select value from cases where cases.name=$1$$;
create function pg_temp.session(n integer,tag text,at_time timestamptz,mode text default 'training',response text default 'typing',
 c integer default 20,a integer default 20,ms integer default 10000,state text default 'finished',origin text default 'server') returns uuid
language plpgsql as $$declare sid uuid:=gen_random_uuid();begin
 insert into public.wat_sessions(id,user_id,client_session_id,wat_set_id,set_version,kind,practice_mode,response_mode,source,timing_trust,status,
  started_at,expires_at,finished_at,finish_reason,imported_at,created_at,updated_at)
 values(sid,pg_temp.actor(n),tag,'7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1',1,'diagnostic',mode::public.practice_mode,response::public.response_mode,
  origin::public.session_source,case when origin='server' then 'server_verified'::public.timing_trust else 'client_reported'::public.timing_trust end,
  case when origin='server' then 'in_progress'::public.session_status else 'finished'::public.session_status end,at_time,at_time+interval '30 minutes',
  case when origin<>'server' then at_time+interval '5 minutes' end,case when origin<>'server' then 'manual'::public.finish_reason end,
  case when origin<>'server' then at_time+interval '6 minutes' end,at_time,at_time);
 insert into public.wat_responses(session_id,user_id,position,word,source,completed,status,answer,time_used_ms)
 select sid,pg_temp.actor(n),position,word,case when response='paper' then 'ocr_confirmed'::public.response_source
  when origin='legacy_local_storage' then 'legacy_typed'::public.response_source else 'typed'::public.response_source end,
  position<=c,case when position<=a then 'answered'::public.response_status when position<=c then 'blank'::public.response_status else 'not_attempted'::public.response_status end,
  case when position<=a then 'PRIVATE-PROGRESS-ANSWER' else '' end,case when position<=c then ms end
 from public.wat_set_items where wat_set_id='7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1' and version=1;
 if origin='server' and state<>'in_progress' then
  update public.wat_sessions set status=case when response='paper' then 'awaiting_upload'::public.session_status else 'finished'::public.session_status end,
   finished_at=at_time+interval '5 minutes',finish_reason='manual',ended_early=c<20 where id=sid;
 end if;
 return sid;
end$$;
create function pg_temp.report(sid uuid,score numeric,weak jsonb default '[]',drill text default 'ACTOR_ACTION_DRILL',job_state text default 'succeeded') returns void
language plpgsql as $$declare s public.wat_sessions; jid uuid:=gen_random_uuid();begin
 select * into s from public.wat_sessions where id=sid;
 insert into public.processing_jobs(id,user_id,session_id,type,status,max_attempts,attempt,created_at,updated_at,started_at,completed_at,locked_at,locked_by)
 values(jid,s.user_id,s.id,'feedback',job_state::public.job_status,2,case when job_state='queued' then 0 else 1 end,s.started_at+interval '6 minutes',s.started_at+interval '8 minutes',
  case when job_state<>'queued' then s.started_at+interval '7 minutes' end,case when job_state in ('succeeded','failed') then s.started_at+interval '8 minutes' end,
  case when job_state='processing' then s.started_at+interval '7 minutes' end,case when job_state='processing' then gen_random_uuid() end);
 insert into public.feedback_reports(user_id,session_id,job_id,rubric_version,prompt_version,model_provider,model_name,overall_score,narrative,summary,generated_at)
 values(s.user_id,s.id,jid,'wat-rubric-v1','synthetic-progress','google_gemini','synthetic-model',score,'PRIVATE-PROGRESS-NARRATIVE',
  jsonb_build_object('narrative','PRIVATE-PROGRESS-NARRATIVE','strengths','[]'::jsonb,'weak_areas',weak,
   'next_drill',jsonb_build_object('code',drill,'title','Practice drill','instructions','Practice clear actions.','recommended_items',10)),s.started_at+interval '8 minutes');
 if job_state in ('succeeded','failed','processing') then
  update public.wat_sessions set status='feedback_queued' where id=sid;
  update public.wat_sessions set status='feedback_processing' where id=sid;
  if job_state<>'processing' then update public.wat_sessions set status=case when job_state='succeeded' then 'ready'::public.session_status else 'failed'::public.session_status end where id=sid;end if;
 end if;
end$$;
create function pg_temp.weak(code text,label text default 'Practice detail') returns jsonb language sql immutable as $$select jsonb_build_object('code',code,'label',label,'evidence_positions',jsonb_build_array(1),'recommendation','Use a concrete action.')$$;
grant execute on all functions in schema pg_temp to authenticated;
insert into auth.users(id,email) select pg_temp.actor(n),'progress-'||n||'@example.invalid' from generate_series(601,610)n;

select ok(not has_function_privilege('anon','public.qiyadat_progress(text,text,text,text)','EXECUTE'),'Progress is not anonymous');
select ok(has_function_privilege('authenticated','public.qiyadat_progress(text,text,text,text)','EXECUTE'),'Candidate can read own progress');
select ok(not (select prosecdef from pg_proc where oid='public.qiyadat_progress(text,text,text,text)'::regprocedure),'Progress uses invoker privileges and RLS');
select is((select proconfig::text from pg_proc where oid='public.qiyadat_progress(text,text,text,text)'::regprocedure),'{"search_path=\"\""}','Fixed empty search path');
select is((select pronargs::integer from pg_proc where oid='public.qiyadat_progress(text,text,text,text)'::regprocedure),4,'No actor or clock argument');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000602"}',true);
select pg_temp.put('empty',public.qiyadat_progress());
select is(pg_temp.get('empty')#>>'{range,key}','30d','Default range');
select is(pg_temp.get('empty')#>>'{range,timezone}','Asia/Karachi','Profile timezone');
select is(pg_temp.get('empty')#>>'{totals,sessions}','0','Empty activity count');
select is(pg_temp.get('empty')#>>'{metrics,completion_percent}','0.0','Empty completion is zero');
select is(pg_temp.get('empty')#>'{metrics,average_report_score}','null'::jsonb,'Missing score is null');
select is(pg_temp.get('empty')#>'{metrics,average_response_seconds}','null'::jsonb,'Missing timing is null');
select is(pg_temp.get('empty')->'trends','[]'::jsonb,'No invented trends');
select is(pg_temp.get('empty')->'weak_areas','[]'::jsonb,'No invented weakness');
select is(public.qiyadat_progress('all')#>>'{range,from}','2026-03-09T19:00:00.000000Z','Empty all begins local today');
select is(public.qiyadat_progress('7d','none')->'weekly_comparison','null'::jsonb,'No comparison is explicit null');
select is(pg_temp.failure($q$select public.qiyadat_progress('week')$q$),'VALIDATION_ERROR','Invalid range');
select is(pg_temp.failure($q$select public.qiyadat_progress('7d','bad')$q$),'VALIDATION_ERROR','Invalid comparison');
select is(pg_temp.failure($q$select public.qiyadat_progress('7d','none','exam')$q$),'VALIDATION_ERROR','Invalid practice mode');
select is(pg_temp.failure($q$select public.qiyadat_progress('7d','none','all','pdf')$q$),'VALIDATION_ERROR','Invalid response mode');
select is(pg_temp.failure($q$select public.qiyadat_progress(null)$q$),'VALIDATION_ERROR','Null option rejected');
reset role;

select pg_temp.put('one',to_jsonb(pg_temp.session(601,'typed','2026-03-10T05:00:00Z','training','typing',20,18,11250)));
select pg_temp.put('two',to_jsonb(pg_temp.session(601,'partial','2026-03-09T05:00:00Z','simulation','typing',10,8,15000)));
select pg_temp.session(601,'paper','2026-03-08T05:00:00Z','training','paper',20,0,null,'awaiting_upload');
select pg_temp.session(601,'legacy-sim','2026-03-07T05:00:00Z','simulation','typing',20,20,999999,'finished','legacy_local_storage');
select pg_temp.session(601,'guest-training','2026-03-06T05:00:00Z','training','typing',20,20,10000,'finished','guest_local');
select pg_temp.session(601,'unfinished','2026-03-10T06:00:00Z','training','typing',2,1,null,'in_progress');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000601"}',true);
select pg_temp.put('main',public.qiyadat_progress());
select is(pg_temp.get('main')->'totals','{"sessions":6,"completed_sessions":5,"words_presented":120,"answers_recorded":67,"reports":0}'::jsonb,'Totals use canonical words, not OCR drafts');
select is(pg_temp.get('main')#>>'{metrics,completion_percent}','76.7','Word-weighted completion rounds once');
select is(pg_temp.get('main')#>>'{metrics,average_response_seconds}','11.5','Response-weighted timing excludes imported simulation');
select is(public.qiyadat_progress('30d','none','simulation')#>>'{metrics,average_response_seconds}','15.0','Simulation timing trust');
select is(public.qiyadat_progress('30d','none','all','paper')#>'{metrics,average_response_seconds}','null'::jsonb,'Missing paper timing stays null');
select is(public.qiyadat_progress('30d','none','all','paper')#>>'{totals,completed_sessions}','1','Finished paper practice is completed before OCR');
select is(public.qiyadat_progress('30d','none','training','typing')#>>'{totals,sessions}','3','Combined mode filters include partial activity');
select is(public.qiyadat_progress('30d','none','simulation','paper')#>>'{totals,sessions}','0','Combined empty filter');
select is(jsonb_array_length(pg_temp.get('main')->'trends'),5,'Only completed sessions trend');
select is(pg_temp.get('main')#>>'{metrics,current_streak_days}','5','Distinct practice dates form streak');
select is(pg_temp.get('main')#>>'{trends,0,date}','2026-03-06','Chronological trend order');
select is(pg_temp.get('main')#>'{trends,1,average_response_seconds}','null'::jsonb,'Imported simulation trend timing is null');
select ok(position('PRIVATE-' in pg_temp.get('main')::text)=0,'No answers or narrative in analytics');
reset role;

select pg_temp.session(604,'lower7','2026-03-03T19:00:00Z');
select pg_temp.session(604,'before7','2026-03-03T18:59:59.999999Z');
select pg_temp.session(604,'lower30','2026-02-08T19:00:00Z');
select pg_temp.session(604,'before30','2026-02-08T18:59:59.999999Z');
select pg_temp.session(604,'lower90','2025-12-10T19:00:00Z');
select pg_temp.session(604,'before90','2025-12-10T18:59:59.999999Z');
select pg_temp.session(604,'before-upper','2026-03-10T18:59:59.999999Z');
select pg_temp.session(604,'upper','2026-03-10T19:00:00Z');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000604"}',true);
select is(public.qiyadat_progress('7d')#>>'{totals,sessions}','2','Exact 7-day lower included and upper excluded');
select is(public.qiyadat_progress('30d')#>>'{totals,sessions}','4','Exact 30-day lower included');
select is(public.qiyadat_progress('90d')#>>'{totals,sessions}','6','Exact 90-day lower included');
select is(public.qiyadat_progress('all')#>>'{totals,sessions}','7','All excludes the upper boundary');
select is(public.qiyadat_progress('all')#>>'{range,from}','2025-12-10T18:59:59.999999Z','All begins earliest included instant');
select is(public.qiyadat_progress('7d')#>>'{range,from}','2026-03-03T19:00:00.000000Z','Karachi local midnight crosses UTC date');
select is(public.qiyadat_progress('30d')#>>'{range,from}','2026-02-08T19:00:00.000000Z','30 calendar dates include today');
select is(public.qiyadat_progress('90d')#>>'{range,from}','2025-12-10T19:00:00.000000Z','90 calendar dates include today');
select is(public.qiyadat_progress('7d')#>>'{range,to}','2026-03-10T19:00:00.000000Z','Upper boundary is tomorrow local midnight');
reset role;

update public.profiles set timezone='America/New_York' where id=pg_temp.actor(605);
select pg_temp.session(605,'dst-before','2026-03-04T04:59:59.999999Z');
select pg_temp.session(605,'dst-lower','2026-03-04T05:00:00Z');
select pg_temp.session(605,'dst-upper','2026-03-11T04:00:00Z');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000605"}',true);
select pg_temp.put('dst',public.qiyadat_progress('7d'));
select is(pg_temp.get('dst')#>>'{totals,sessions}','1','Spring DST half-open bounds');
select is(pg_temp.get('dst')#>>'{range,from}','2026-03-04T05:00:00.000000Z','Spring lower midnight offset');
select is(pg_temp.get('dst')#>>'{range,to}','2026-03-11T04:00:00.000000Z','Spring upper midnight offset');
select is(extract(epoch from ((pg_temp.get('dst')#>>'{range,to}')::timestamptz-(pg_temp.get('dst')#>>'{range,from}')::timestamptz))::integer,167*3600,'Spring range is 167 hours, not fixed 168');
reset role;
create or replace function private.progress_clock() returns timestamptz language sql stable security invoker set search_path = '' as $$select '2026-11-03T10:00:00Z'::timestamptz$$;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000605"}',true);
select is(public.qiyadat_progress('7d')#>>'{range,from}','2026-10-28T04:00:00.000000Z','Autumn lower midnight offset');
select is(public.qiyadat_progress('7d')#>>'{range,to}','2026-11-04T05:00:00.000000Z','Autumn upper midnight offset');
reset role;
create or replace function private.progress_clock() returns timestamptz language sql stable security invoker set search_path = '' as $$select '2026-03-10T10:00:00Z'::timestamptz$$;

select pg_temp.session(606,'yesterday1','2026-03-09T05:00:00Z');
select pg_temp.session(606,'yesterday2','2026-03-09T06:00:00Z');
select pg_temp.session(606,'preceding','2026-03-08T05:00:00Z');
select pg_temp.session(606,'before-gap','2026-03-06T05:00:00Z');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000606"}',true);
select is(public.qiyadat_progress('7d')#>>'{metrics,current_streak_days}','2','Yesterday continues streak, duplicate dates do not add days');
reset role;
create or replace function private.progress_clock() returns timestamptz language sql stable security invoker set search_path = '' as $$select '2026-03-12T10:00:00Z'::timestamptz$$;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000606"}',true);
select is(public.qiyadat_progress()#>>'{metrics,current_streak_days}','0','A full missed day breaks current streak');
reset role;
create or replace function private.progress_clock() returns timestamptz language sql stable security invoker set search_path = '' as $$select '2026-03-10T10:00:00Z'::timestamptz$$;

select pg_temp.report(pg_temp.session(607,'previous1','2026-02-28T05:00:00Z'),4,jsonb_build_array(pg_temp.weak('LOW_SPECIFICITY'),pg_temp.weak('LOW_CLARITY')));
select pg_temp.report(pg_temp.session(607,'previous2','2026-03-01T05:00:00Z'),6,jsonb_build_array(pg_temp.weak('LOW_SPECIFICITY'),pg_temp.weak('LOW_REALISM')));
select pg_temp.report(pg_temp.session(607,'current1','2026-03-08T05:00:00Z'),8,jsonb_build_array(pg_temp.weak('LOW_CLARITY'),pg_temp.weak('LOW_AGENCY'),pg_temp.weak('NEGATIVE_FRAMING')));
select pg_temp.report(pg_temp.session(607,'current2','2026-03-09T05:00:00Z'),10,jsonb_build_array(pg_temp.weak('LOW_CLARITY'),pg_temp.weak('LOW_AGENCY'),
 pg_temp.weak('LOW_SPECIFICITY','Latest specificity'),pg_temp.weak('LOW_SPECIFICITY','Duplicate ignored'),pg_temp.weak('LOW_REALISM')),'PRACTICAL_RESPONSE_DRILL');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000607"}',true);
select pg_temp.put('reports',public.qiyadat_progress());
select is(pg_temp.get('reports')#>>'{totals,reports}','4','Only eligible final reports counted');
select is(pg_temp.get('reports')#>>'{metrics,average_report_score}','7.0','Existing overall scores averaged');
select is(pg_temp.get('reports')#>>'{weekly_comparison,current,sessions}','2','Current rolling local week');
select is(pg_temp.get('reports')#>>'{weekly_comparison,previous,sessions}','2','Immediately preceding local week');
select is(pg_temp.get('reports')#>>'{weekly_comparison,changes,average_score}','4.0','Weekly score change');
select is(pg_temp.get('reports')#>>'{weekly_comparison,changes,completion_percentage_points}','0.0','Weekly completion point change');
select is(jsonb_array_length(pg_temp.get('reports')->'weak_areas'),4,'One-off weakness excluded, repeated weaknesses included');
select is(pg_temp.get('reports')#>>'{weak_areas,0,code}','LOW_CLARITY','Weakness count then code sorting');
select is(pg_temp.get('reports')#>>'{weak_areas,0,recent_direction}','declining','Higher occurrence rate declines');
select is(pg_temp.get('reports')#>>'{weak_areas,1,code}','LOW_SPECIFICITY','Tied count sorts by code');
select is(pg_temp.get('reports')#>>'{weak_areas,1,report_count}','3','Duplicate weakness counted once per report');
select is(pg_temp.get('reports')#>>'{weak_areas,1,recent_direction}','improving','Lower occurrence rate improves');
select is(pg_temp.get('reports')#>>'{weak_areas,1,label}','Latest specificity','Most recent eligible label');
select is(pg_temp.get('reports')#>>'{weak_areas,1,recommended_drill}','PRACTICAL_RESPONSE_DRILL','Most recent eligible report drill');
select is(pg_temp.get('reports')#>>'{weak_areas,3,recent_direction}','stable','Equal occurrence rate is stable');
select is(public.qiyadat_progress('7d','none')#>>'{weak_areas,0,recent_direction}','declining','Weak direction is independent of comparison object');
select is(public.qiyadat_progress('30d','none','simulation')->'weak_areas','[]'::jsonb,'Weaknesses obey practice filter');
select is(public.qiyadat_progress('30d','none','all','paper')->'weak_areas','[]'::jsonb,'Reports obey response filter');
reset role;

select pg_temp.report(pg_temp.session(609,'null-score','2026-03-09T05:00:00Z'),null);
select pg_temp.report(pg_temp.session(609,'processing','2026-03-08T05:00:00Z'),9,'[]','ACTOR_ACTION_DRILL','processing');
select pg_temp.report(pg_temp.session(609,'failed','2026-03-07T05:00:00Z'),10,'[]','ACTOR_ACTION_DRILL','failed');
select pg_temp.session(609,'no-report','2026-03-06T05:00:00Z');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000609"}',true);
select is(public.qiyadat_progress()#>>'{totals,reports}','1','Unfinished and failed report jobs excluded even if a row is corruptly staged');
select is(public.qiyadat_progress()#>>'{totals,completed_sessions}','3','Failed session is not a completed practice');
select is(public.qiyadat_progress()#>'{metrics,average_report_score}','null'::jsonb,'Unscored ready report does not become zero');
select is(public.qiyadat_progress()#>'{weekly_comparison,changes,average_score}','null'::jsonb,'Weekly score change needs both scores');
reset role;
select pg_temp.report(pg_temp.session(609,'score-a','2026-03-09T06:00:00Z'),4.4);
select pg_temp.report(pg_temp.session(609,'score-b','2026-03-09T07:00:00Z'),5.5);
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000609"}',true);
select is(public.qiyadat_progress()#>>'{metrics,average_report_score}','5.0','Report decimal averages round to one place');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000602"}',true);
select is(public.qiyadat_progress()#>>'{totals,sessions}','0','Other users cannot influence empty account analytics');
select is(public.qiyadat_progress()->'weak_areas','[]'::jsonb,'Other user weakness text is isolated');
reset role;
update public.profiles set access_disabled_at=statement_timestamp() where id=pg_temp.actor(610);
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000610"}',true);
select is(pg_temp.failure('select public.qiyadat_progress()'),'AUTH_INVALID','Disabled account cannot aggregate data');
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select is(pg_temp.failure('select public.qiyadat_progress()'),'AUTH_INVALID','No arbitrary fallback account');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000602"}',true);
select ok((select bool_and(public.qiyadat_progress(r,c,p,m)#>>'{range,key}'=r)
 from unnest(array['7d','30d','90d','all'])r cross join unnest(array['none','previous_period'])c
 cross join unnest(array['all','training','simulation'])p cross join unnest(array['all','typing','paper'])m),'Every allowed query combination');
reset role;
select pg_temp.put('tie1',to_jsonb(pg_temp.session(608,'tie1','2026-03-09T20:00:00Z')));
select pg_temp.put('tie2',to_jsonb(pg_temp.session(608,'tie2','2026-03-09T20:00:00Z')));
select pg_temp.report((pg_temp.get('tie1')#>>'{}')::uuid,8,jsonb_build_array(pg_temp.weak('LOW_AGENCY')));
select pg_temp.report((pg_temp.get('tie2')#>>'{}')::uuid,8,jsonb_build_array(pg_temp.weak('LOW_AGENCY')));
set local timezone='Pacific/Honolulu';
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000608"}',true);
select is(public.qiyadat_progress()#>>'{trends,0,session_id}',least(pg_temp.get('tie1')#>>'{}',pg_temp.get('tie2')#>>'{}'),'Stable UUID tie-breaker');
select is(public.qiyadat_progress()#>>'{trends,0,date}','2026-03-10','Profile local trend date, not UTC date');
select is(public.qiyadat_progress()#>>'{range,to}','2026-03-10T19:00:00.000000Z','Database connection timezone does not affect output');
select is(public.qiyadat_progress()#>>'{weak_areas,0,recent_direction}','stable','Insufficient previous report evidence is stable');
select is(public.qiyadat_progress()#>>'{metrics,current_streak_days}','1','Same-day sessions count once');
reset role;
set local timezone='UTC';
select pg_temp.session(603,'prev-before','2026-02-24T18:59:59.999999Z');
select pg_temp.session(603,'prev-lower','2026-02-24T19:00:00Z','training','typing',0,0,null);
select pg_temp.session(603,'prev-last','2026-03-03T18:59:59.999999Z','training','typing',0,0,null);
select pg_temp.session(603,'current-lower','2026-03-03T19:00:00Z','training','typing',10,8,10000);
select pg_temp.session(603,'week-upper','2026-03-10T19:00:00Z');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000603"}',true);
select is(public.qiyadat_progress('7d')#>>'{weekly_comparison,current,sessions}','1','Current weekly lower inclusive, upper exclusive');
select is(public.qiyadat_progress('7d')#>>'{weekly_comparison,previous,sessions}','2','Previous weekly lower inclusive, upper exclusive, independent of selected range');
select is(public.qiyadat_progress('7d')#>>'{weekly_comparison,changes,completion_percentage_points}','50.0','Completion change uses word percentage points');
reset role;
select * from finish();
rollback;
