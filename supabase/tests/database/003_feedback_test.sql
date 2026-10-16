begin;
set local search_path=public,extensions;
select no_plan();
create function pg_temp.failure(statement text) returns text language plpgsql as $$
begin execute statement;return 'OK';exception when others then return case when sqlstate='P0001' then sqlerrm else sqlstate end;end $$;
create temp table cases(name text primary key,value jsonb);
grant all on cases to authenticated,service_role;
create function pg_temp.put(name text,value jsonb) returns void language sql as $$ insert into cases values(name,value) on conflict(name) do update set value=excluded.value $$;
create function pg_temp.get(name text) returns jsonb language sql stable as $$select value from cases where cases.name=$1$$;
create function pg_temp.actor(n integer) returns uuid language sql immutable as $$select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid$$;
create function pg_temp.sid(name text) returns uuid language sql stable as $$select (pg_temp.get(name)#>>'{body,data,id}')::uuid$$;
create function pg_temp.jid(name text) returns uuid language sql stable as $$select (pg_temp.get(name)#>>'{body,data,job_id}')::uuid$$;
create function pg_temp.session(actor uuid,client text,paper boolean default false,blank boolean default false) returns jsonb language plpgsql as $$
declare result jsonb;begin
 result:=public.qiyadat_mutate(actor,'start',jsonb_build_object('client_session_id',client,'set_id','7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1',
  'set_version',1,'kind','diagnostic','practice_mode','training','response_mode',case when paper then 'paper' else 'typing' end,'session_size',20),client||'-start-key-00001');
 if not paper and not blank then perform public.qiyadat_mutate(actor,'answer','{"answer":"A person takes a practical step."}',null,(result#>>'{body,data,id}')::uuid,1);end if;
 perform public.qiyadat_mutate(actor,'finish','{"reason":"manual"}',client||'-finish-key-0001',(result#>>'{body,data,id}')::uuid);
 return result;
end $$;
create function pg_temp.output(session_identifier uuid) returns jsonb language sql stable as $$
 select jsonb_build_object('sentences',(select jsonb_agg(jsonb_build_object('position',position,'status',case when status='answered' then 'scored' else 'not_scored' end,
  'tone_rating',case when status='answered' then 4 end,'tone_label',case when status='answered' then 'constructive' end,'tone_note',case when status='answered' then 'Practical wording.' end,
  'agency_rating',case when status='answered' then 4 end,'agency_label',case when status='answered' then 'active' end,'agency_note',case when status='answered' then 'Names an action.' end,
  'clarity_rating',case when status='answered' then 5 end,'clarity_label',case when status='answered' then 'clear' end,'clarity_note',case when status='answered' then 'Complete idea.' end,
  'realism_rating',case when status='answered' then 4 end,'realism_label',case when status='answered' then 'grounded' end,'realism_note',case when status='answered' then 'Believable action.' end,
  'strength',case when status='answered' then 'Clear action.' end,'feedback',case when status='answered' then 'Name a concrete situation.' else 'No response was recorded.' end,'safety_flags','[]'::jsonb) order by position)
 from public.wat_responses where session_id=session_identifier),
 'summary','{"narrative":"Recorded responses describe actions clearly.","strengths":[{"code":"CLEAR_EXPRESSION","label":"Clear expression","evidence_positions":[1]}],"weak_areas":[],"next_drill":{"code":"ACTOR_ACTION_DRILL","title":"Actor and action drill","instructions":"Write ten short responses with a concrete action.","recommended_items":10}}'::jsonb);
$$;
grant execute on all functions in schema pg_temp to anon,authenticated,service_role;
insert into auth.users(id,email) select pg_temp.actor(n),'feedback-'||n||'@example.invalid' from generate_series(301,306)n;
select ok(not has_function_privilege('anon','public.qiyadat_feedback_claim(uuid,text,text)','EXECUTE'),'Anonymous cannot claim feedback');
select ok(not has_function_privilege('authenticated','public.qiyadat_request_report(uuid,uuid,jsonb,text)','EXECUTE'),'Browser cannot reserve quota with forged identity');
select ok(not has_function_privilege('authenticated','public.qiyadat_feedback_complete(uuid,uuid,jsonb,text)','EXECUTE'),'Browser cannot forge final ratings');
select ok(not has_table_privilege('authenticated','private.feedback_provider_windows','SELECT'),'Provider cap is server-only');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid='private.feedback_provider_windows'::regclass),'Provider cap uses forced RLS');
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select pg_temp.put('free',pg_temp.session(pg_temp.actor(301),'phase3-free'));
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(302),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-wrong-owner-key')$q$),'NOT_FOUND','Other owner gets not found');
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-disabled-key')$q$),'FEATURE_DISABLED','Feedback defaults to disabled');
update app_settings set value='true' where key='feedback_enabled';
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-no-consent-key')$q$),'AI_CONSENT_REQUIRED','Consent required');
insert into profile_consents(user_id,terms_version,accepted) select pg_temp.actor(n),'2026-10-01',true from generate_series(301,306)n;
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"future"}','phase3-wrong-rubric-key')$q$),'VALIDATION_ERROR','Unknown rubric rejected');
select pg_temp.put('request',public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-free-request-key'));
select is(pg_temp.get('request')->>'status','202','Free report accepted asynchronously');
select is((select count(*)::integer from usage_reservations where user_id=pg_temp.actor(301) and type='diagnostic_report' and status='reserved'),1,'Free quota reserved once');
select is(public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-free-request-key'),pg_temp.get('request'),'Same key replays current queued result');
select is(public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-free-second-key')#>>'{body,data,job_id}',pg_temp.jid('request')::text,'Repeated click with new key returns same active job');
select is((select count(*)::integer from processing_jobs where type='feedback'),1,'Only one active job exists');
select is((select status::text from wat_sessions where id=pg_temp.sid('free')),'feedback_queued','Enqueue and session transition are atomic');
select pg_temp.put('claim',public.qiyadat_feedback_claim(pg_temp.actor(399),'synthetic-model','synthetic-prompt'));
select is(pg_temp.get('claim')->>'attempt','1','Claim increments attempt');
select is((select status::text from wat_sessions where id=pg_temp.sid('free')),'feedback_processing','Claim advances session');
select ok(public.qiyadat_feedback_claim(pg_temp.actor(398),'synthetic-model','synthetic-prompt') is null,'Second worker cannot claim processing job');
select ok(not public.qiyadat_feedback_fail(pg_temp.jid('request'),pg_temp.actor(398),'PROVIDER_UNAVAILABLE',true),'Wrong worker cannot fail job');
select is(pg_temp.failure($q$select public.qiyadat_feedback_complete(pg_temp.jid('request'),pg_temp.actor(398),pg_temp.output(pg_temp.sid('free')),'synthetic-model-v1')$q$),'SESSION_STATE_CONFLICT','Wrong worker cannot complete job');
select is(pg_temp.failure($q$select public.qiyadat_feedback_complete(pg_temp.jid('request'),pg_temp.actor(399),jsonb_set(pg_temp.output(pg_temp.sid('free')),'{sentences}',(pg_temp.output(pg_temp.sid('free'))->'sentences')-0),'synthetic-v1')$q$),'AI_OUTPUT_INVALID','Missing output sentence rejected');
select is((select count(*)::integer from feedback_reports),0,'Invalid completion rolls back whole report');
select is((select status::text from usage_reservations where job_id=pg_temp.jid('request')),'reserved','Invalid completion leaves reservation intact');
select pg_temp.put('report',to_jsonb(public.qiyadat_feedback_complete(pg_temp.jid('request'),pg_temp.actor(399),pg_temp.output(pg_temp.sid('free')),'synthetic-model-v1')));
select is((select count(*)::integer from feedback_items),20,'Atomic success persists 20 items');
select is((select overall_score::text from feedback_reports),'8.5','Backend derives overall from ratings only');
select is((select clarity_score::text from feedback_reports),'10.0','Dimension averages exclude 19 blanks');
select is((select count(*)::integer from feedback_items where status='not_scored' and score is null),19,'Blank items do not affect scoring');
select is((select status::text from processing_jobs where id=pg_temp.jid('request')),'succeeded','Success finalizes job');
select is((select status::text from usage_reservations where job_id=pg_temp.jid('request')),'consumed','Success consumes reservation');
select is((select status::text from wat_sessions where id=pg_temp.sid('free')),'ready','Success readies session');
select ok((select locked_by is null and locked_at is null from processing_jobs where id=pg_temp.jid('request')),'Success clears lease');
select is(to_jsonb(public.qiyadat_feedback_complete(pg_temp.jid('request'),pg_temp.actor(399),pg_temp.output(pg_temp.sid('free')),'synthetic-model-v1')),pg_temp.get('report'),'Lost success acknowledgement is safe to replay');
select is((select count(*)::integer from feedback_reports),1,'Replay cannot duplicate final report');
select is(public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-free-request-key')->>'status','200','Original key after success returns report reference');
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(301),pg_temp.sid('free'),'{"rubric_version":"wat-rubric-v1"}','phase3-new-final-key')$q$),'REPORT_ALREADY_EXISTS','New key cannot create second final free report');

-- Active paid access grants exactly three transactional reservations.
insert into entitlements(user_id,type,starts_at,expires_at) values(pg_temp.actor(302),'founding_30d',now()-interval '1 day',now()+interval '29 days');
select pg_temp.put('paid1',pg_temp.session(pg_temp.actor(302),'phase3-paid1'));
select pg_temp.put('paid2',pg_temp.session(pg_temp.actor(302),'phase3-paid2'));
select pg_temp.put('paid3',pg_temp.session(pg_temp.actor(302),'phase3-paid3'));
select pg_temp.put('paid4',pg_temp.session(pg_temp.actor(302),'phase3-paid4'));
select pg_temp.put('p1',public.qiyadat_request_report(pg_temp.actor(302),pg_temp.sid('paid1'),'{"rubric_version":"wat-rubric-v1"}','phase3-paid1-report-key'));
select pg_temp.put('p2',public.qiyadat_request_report(pg_temp.actor(302),pg_temp.sid('paid2'),'{"rubric_version":"wat-rubric-v1"}','phase3-paid2-report-key'));
select pg_temp.put('p3',public.qiyadat_request_report(pg_temp.actor(302),pg_temp.sid('paid3'),'{"rubric_version":"wat-rubric-v1"}','phase3-paid3-report-key'));
select is(pg_temp.get('p3')#>>'{body,data,quota,remaining_rolling_24h}','0','Third reservation leaves zero slots');
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(302),pg_temp.sid('paid4'),'{"rubric_version":"wat-rubric-v1"}','phase3-paid4-report-key')$q$),'REPORT_LIMIT_REACHED','Fourth report rejected in rolling window');
select is((select count(*)::integer from api_idempotency_keys where idempotency_key='phase3-paid4-report-key'),0,'Quota rejection rolls back idempotency reservation');
select pg_temp.put('paid_claim',public.qiyadat_feedback_claim(pg_temp.actor(399),'synthetic-model','synthetic-prompt'));
select ok(public.qiyadat_feedback_fail((pg_temp.get('paid_claim')->>'id')::uuid,pg_temp.actor(399),'AI_OUTPUT_INVALID',false),'Terminal failure succeeds atomically');
select is((select count(*)::integer from usage_reservations where user_id=pg_temp.actor(302) and status='reserved'),2,'Terminal failure releases slot');
select pg_temp.put('p4',public.qiyadat_request_report(pg_temp.actor(302),pg_temp.sid('paid4'),'{"rubric_version":"wat-rubric-v1"}','phase3-paid4-report-key'));
select is(pg_temp.get('p4')->>'status','202','Released slot can be reserved again');
select pg_temp.put('retry_claim',public.qiyadat_feedback_claim(pg_temp.actor(399),'synthetic-model','synthetic-prompt'));
select ok(public.qiyadat_feedback_fail((pg_temp.get('retry_claim')->>'id')::uuid,pg_temp.actor(399),'PROVIDER_UNAVAILABLE',true),'Transient failure schedules retry');
select is((select status::text from processing_jobs where id=(pg_temp.get('retry_claim')->>'id')::uuid),'retrying','Retry retains durable state');
select ok((select next_attempt_at>statement_timestamp() from processing_jobs where id=(pg_temp.get('retry_claim')->>'id')::uuid),'Retry uses bounded delay');
select is((select status::text from usage_reservations where job_id=(pg_temp.get('retry_claim')->>'id')::uuid),'reserved','Retry retains quota slot');
-- Deterministic stale clocks exercise recovery without real-time waits.
select pg_temp.put('stale',public.qiyadat_feedback_claim(pg_temp.actor(399),'synthetic-model','synthetic-prompt'));
select is(private.feedback_recover(statement_timestamp()+interval '5 minutes 1 second'),1,'Stale processing lease recovers');
select ok(not public.qiyadat_feedback_fail((pg_temp.get('stale')->>'id')::uuid,pg_temp.actor(399),'AI_OUTPUT_INVALID',false),'Old worker cannot alter recovered job');
update processing_jobs set next_attempt_at=now()-interval '1 second' where status='retrying';
select pg_temp.put('second',public.qiyadat_feedback_claim(pg_temp.actor(398),'new-model','new-prompt'));
select is(pg_temp.get('second')->>'attempt','2','Second attempt bounded at two');
select is(pg_temp.get('second')->>'model','synthetic-model','Retry preserves original model snapshot');
select ok(public.qiyadat_feedback_fail((pg_temp.get('second')->>'id')::uuid,pg_temp.actor(398),'AI_OUTPUT_INVALID',true),'Second invalid output becomes terminal');
select is((select status::text from processing_jobs where id=(pg_temp.get('second')->>'id')::uuid),'failed','No third provider attempt');

-- Trusted failed free report recovery never creates a new demo.
select pg_temp.put('retryfree',pg_temp.session(pg_temp.actor(303),'phase3-retryfree'));
select pg_temp.put('retryrequest',public.qiyadat_request_report(pg_temp.actor(303),pg_temp.sid('retryfree'),'{"rubric_version":"wat-rubric-v1"}','phase3-retryfree-key'));
-- Drain paid work before claiming this fixture.
do $$declare claim jsonb;begin loop claim:=public.qiyadat_feedback_claim(pg_temp.actor(399),'synthetic-model','synthetic-prompt');exit when claim is null;
 perform public.qiyadat_feedback_fail((claim->>'id')::uuid,pg_temp.actor(399),'PROVIDER_UNAVAILABLE',false);end loop;end$$;
select is((select status::text from usage_reservations where job_id=pg_temp.jid('retryrequest')),'released','Free technical failure releases lifetime report slot');
select is(public.qiyadat_request_report(pg_temp.actor(303),pg_temp.sid('retryfree'),'{"rubric_version":"wat-rubric-v1"}','phase3-retryfree-new-key')->>'status','202','Same failed demo can retry with new key');
select is((select count(*)::integer from wat_sessions where user_id=pg_temp.actor(303) and is_free_demo),1,'Technical recovery preserves one canonical demo');

select pg_temp.put('cap',pg_temp.session(pg_temp.actor(304),'phase3-cap'));
update app_settings set value='0' where key='feedback_daily_provider_cap';
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(304),pg_temp.sid('cap'),'{"rubric_version":"wat-rubric-v1"}','phase3-cap-report-key')$q$),'GLOBAL_QUOTA_EXHAUSTED','Global provider cap prevents reservation');
select is((select count(*)::integer from usage_reservations where user_id=pg_temp.actor(304)),0,'Global cap rejection is atomic');
update app_settings set value='100' where key='feedback_daily_provider_cap';
insert into profile_consents(user_id,terms_version,accepted,accepted_at) values(pg_temp.actor(304),'obsolete',true,statement_timestamp());
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(304),pg_temp.sid('cap'),'{"rubric_version":"wat-rubric-v1"}','phase3-stale-consent-key')$q$),'AI_CONSENT_REQUIRED','Obsolete consent cannot authorize new processing');
insert into profile_consents(user_id,terms_version,accepted,accepted_at) values(pg_temp.actor(304),'2026-10-01',true,statement_timestamp());
select pg_temp.put('revoke',public.qiyadat_request_report(pg_temp.actor(304),pg_temp.sid('cap'),'{"rubric_version":"wat-rubric-v1"}','phase3-consent-revoke-key'));
insert into profile_consents(user_id,terms_version,accepted,accepted_at) values(pg_temp.actor(304),'2026-10-01',false,statement_timestamp());
-- Claim the other queued free fixture first, then the revoked fixture.
do $$declare claim jsonb;begin loop claim:=public.qiyadat_feedback_claim(pg_temp.actor(399),'synthetic-model','synthetic-prompt');exit when claim is null;
 perform public.qiyadat_feedback_fail((claim->>'id')::uuid,pg_temp.actor(399),'PROVIDER_UNAVAILABLE',false);end loop;end$$;
select is((select status::text from processing_jobs where id=pg_temp.jid('revoke')),'failed','Consent withdrawal stops queued provider work');
select is((select error_code from processing_jobs where id=pg_temp.jid('revoke')),'AI_CONSENT_REQUIRED','Consent failure uses safe stable code');
select is((select status::text from usage_reservations where job_id=pg_temp.jid('revoke')),'released','Consent failure releases reservation');
select lives_ok($q$select public.qiyadat_mutate(pg_temp.actor(304),'profile','{"accept_ai_processing_terms_version":"2026-10-01"}')$q$,'Current consent can be reaccepted after withdrawal');
select ok(private.feedback_consent(pg_temp.actor(304)),'Reacceptance appends a current true consent event');

update app_settings set value='true' where key='beta_open';
select pg_temp.put('beta1',pg_temp.session(pg_temp.actor(305),'phase3-beta1'));
select pg_temp.put('beta2',pg_temp.session(pg_temp.actor(305),'phase3-beta2'));
select pg_temp.put('beta3',pg_temp.session(pg_temp.actor(305),'phase3-beta3'));
select pg_temp.put('beta4',pg_temp.session(pg_temp.actor(305),'phase3-beta4'));
select pg_temp.put('b1',public.qiyadat_request_report(pg_temp.actor(305),pg_temp.sid('beta1'),'{"rubric_version":"wat-rubric-v1"}','phase3-beta1-report-key'));
select pg_temp.put('b2',public.qiyadat_request_report(pg_temp.actor(305),pg_temp.sid('beta2'),'{"rubric_version":"wat-rubric-v1"}','phase3-beta2-report-key'));
select pg_temp.put('b3',public.qiyadat_request_report(pg_temp.actor(305),pg_temp.sid('beta3'),'{"rubric_version":"wat-rubric-v1"}','phase3-beta3-report-key'));
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(305),pg_temp.sid('beta4'),'{"rubric_version":"wat-rubric-v1"}','phase3-beta4-report-key')$q$),'REPORT_LIMIT_REACHED','Beta has same three-report rolling limit');
select is(private.feedback_quota(pg_temp.actor(305),statement_timestamp()+interval '24 hours 1 second')->>'used_rolling_24h','0','Rolling window expires independently of calendar midnight');
select is(pg_temp.failure($q$select public.qiyadat_request_report(pg_temp.actor(305),pg_temp.sid('beta1'),'{"rubric_version":"future"}','phase3-beta1-report-key')$q$),'IDEMPOTENCY_CONFLICT','Different report input conflicts with existing key');
select pg_temp.put('blank',pg_temp.session(pg_temp.actor(306),'phase3-blank',false,true));
select pg_temp.put('blank_job',public.qiyadat_request_report(pg_temp.actor(306),pg_temp.sid('blank'),'{"rubric_version":"wat-rubric-v1"}','phase3-blank-report-key'));
do $$declare claim jsonb; output jsonb; s uuid;begin loop
 claim:=public.qiyadat_feedback_claim(pg_temp.actor(399),'synthetic-model','synthetic-prompt');exit when claim is null;
 select session_id into s from public.processing_jobs where id=(claim->>'id')::uuid;
 output:=pg_temp.output(s);
 if not exists(select 1 from public.wat_responses where session_id=s and status='answered') then
  output:=jsonb_set(output,'{summary,strengths}','[]'::jsonb);
 end if;
 perform public.qiyadat_feedback_complete((claim->>'id')::uuid,pg_temp.actor(399),output,'synthetic-model-v1');
end loop;end$$;
select ok((select overall_score is null and tone_score is null and clarity_score is null from feedback_reports where session_id=pg_temp.sid('blank')),'All-blank report persists null rubric averages');
select is((select count(*)::integer from feedback_items where session_id=pg_temp.sid('blank') and status='not_scored' and score is null),20,'All 20 blank entries persist as not scored');
select is(public.qiyadat_account_context(pg_temp.actor(306))#>>'{usage,reports_used_rolling_24h}','1','Successful blank report still consumes its requested report slot');
insert into admin_users(user_id,active) values(pg_temp.actor(305),true);
select is(public.qiyadat_job_read(pg_temp.actor(305),pg_temp.jid('request'))->>'status','succeeded','Trusted admin can read safe operational job state');
select ok(not (public.qiyadat_job_read(pg_temp.actor(305),pg_temp.jid('request')) ? 'locked_by'),'Admin job view excludes worker secrets');

reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000301","role":"authenticated"}',true);
select is(jsonb_array_length(public.qiyadat_report_read(pg_temp.sid('free'))->'sentences'),20,'Owner can read complete safe report');
select is(pg_temp.failure($q$select public.qiyadat_report_read(pg_temp.sid('paid1'))$q$),'NOT_FOUND','Other owner report hidden by RLS');
select is((select count(*)::integer from feedback_reports),1,'Report RLS isolates owner');
select is((select count(*)::integer from processing_jobs),1,'Job RLS isolates owner');
select is(pg_temp.failure($q$select public.qiyadat_feedback_claim(pg_temp.actor(399),'model','prompt')$q$),'42501','Candidate cannot call worker RPC');
reset role;
select * from finish();
rollback;
