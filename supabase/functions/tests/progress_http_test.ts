import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {localStatus} from '../../../backend/scripts/local_supabase_cli.ts';
import {validateOutput} from '../_shared/feedback/output.ts';
const local=localStatus(),base=local.API_URL,api=base+'/functions/v1/api/v1',marker=process.env.QIYADAT_PROGRESS_TEST_MARKER;
if(!marker||!process.send)throw new Error('Use the isolated progress HTTP runner.');
interface Actor {id:string;token:string}
const actors:Actor[]=[],inputs=new Map<string,any[]>();let words:any[]=[];
const secretHeaders={apikey:local.SERVICE_ROLE_KEY,Authorization:'Bearer '+local.SERVICE_ROLE_KEY,'Content-Type':'application/json',Prefer:'return=representation'};
async function raw(path:string,options:RequestInit={}){return fetch(base+path,{...options,signal:AbortSignal.timeout(30000)});}
async function service(path:string,method='GET',body?:unknown){const r=await raw('/rest/v1/'+path,{method,headers:secretHeaders,...(body===undefined?{}:{body:JSON.stringify(body)})});
 assert.ok(r.ok,'Synthetic progress fixture operation succeeds');return r.status===204?null:r.json();}
async function actor():Promise<Actor>{
 const email='qiyadat-phase5-'+randomUUID()+'@example.invalid',password=randomUUID()+randomUUID();
 const r=await raw('/auth/v1/admin/users',{method:'POST',headers:secretHeaders,body:JSON.stringify({email,password,email_confirm:true})});assert.equal(r.status,200,'Local synthetic Auth user created');
 const user=await r.json(),a={id:user.id,token:''};actors.push(a);
 const login=await raw('/auth/v1/token?grant_type=password',{method:'POST',headers:{apikey:local.ANON_KEY,'Content-Type':'application/json'},body:JSON.stringify({email,password})});
 assert.equal(login.status,200,'Local synthetic Auth session created');a.token=(await login.json()).access_token;
 process.send!({type:'privacy',values:[email,password,a.token]});return a;
}
async function progress(a:Actor,query='',extra:Record<string,string>={}){
 const r=await fetch(api+'/progress'+(query?'?'+query:''),{headers:{Authorization:'Bearer '+a.token,apikey:local.ANON_KEY,...extra},signal:AbortSignal.timeout(30000)});
 return {r,body:await r.json()};
}
async function data(a:Actor,query=''){const result=await progress(a,query);assert.equal(result.r.status,200);return result.body.data;}
async function session(a:Actor,tag:string,start:string,practice='training',response='typing',completed=20,answered=20,ms:number|null=10000,origin='server',unfinished=false){
 const end=new Date(Date.parse(start)+300000).toISOString(),id=randomUUID();
 await service('wat_sessions','POST',{id,user_id:a.id,client_session_id:'progress-'+tag,wat_set_id:'7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1',set_version:1,kind:'diagnostic',practice_mode:practice,response_mode:response,
  source:origin,timing_trust:origin==='server'?'server_verified':'client_reported',status:origin==='server'?'in_progress':'finished',started_at:start,
  expires_at:new Date(Date.parse(start)+1800000).toISOString(),...(origin==='server'?{}:{finished_at:end,finish_reason:'manual',imported_at:end})});
 const responses=words.map(w=>({session_id:id,user_id:a.id,position:w.position,word:w.word,source:response==='paper'?'ocr_confirmed':origin==='legacy_local_storage'?'legacy_typed':'typed',
  completed:w.position<=completed,status:w.position<=answered?'answered':w.position<=completed?'blank':'not_attempted',
  answer:w.position<=answered?'PRIVATE-PROGRESS-ANSWER-'+marker:'',time_used_ms:w.position<=completed?ms:null}));
 await service('wat_responses','POST',responses);inputs.set(id,responses);
 if(origin==='server'&&!unfinished)await service('wat_sessions?id=eq.'+id,'PATCH',{status:response==='paper'?'awaiting_upload':'finished',finished_at:end,finish_reason:'manual',ended_early:completed<20});
 return id;
}
const weak=(code:string,label='Practice detail')=>({code,label,evidence_positions:[1],recommendation:'Use a concrete actor and action.'});
async function report(a:Actor,sid:string,score:number|null,weaknesses:any[]=[],drill='ACTOR_ACTION_DRILL',state='succeeded'){
 const responses=inputs.get(sid)!,summary={narrative:'PRIVATE-PROGRESS-REPORT-'+marker,strengths:[],weak_areas:weaknesses,
  next_drill:{code:drill,title:'Practice drill',instructions:'Write concrete actions.',recommended_items:10}};
 // Validate the stored summary through the same report-output validator; never call a provider.
 const sentences=responses.map(r=>{const scored=r.status==='answered',item:any={position:r.position,status:scored?'scored':'not_scored',
  strength:scored?'Clear action.':null,feedback:scored?'Use a concrete example.':'No response was recorded.',safety_flags:[]};
  for(const [d,label] of Object.entries({tone:'constructive',agency:'active',clarity:'clear',realism:'grounded'})){
   item[d+'_rating']=scored?4:null;item[d+'_label']=scored?label:null;item[d+'_note']=scored?'Practical wording.':null;}
  return item;});validateOutput({sentences,summary},responses);
 const s=(await service('wat_sessions?select=started_at&id=eq.'+sid))[0],at=Date.parse(s.started_at),jid=randomUUID();
 const time=(offset:number)=>new Date(at+offset*60000).toISOString();
 await service('processing_jobs','POST',{id:jid,user_id:a.id,session_id:sid,type:'feedback',status:state,max_attempts:2,attempt:1,
  created_at:time(6),updated_at:time(8),started_at:time(7),...(state==='processing'?{locked_at:time(7),locked_by:randomUUID()}:{completed_at:time(8)})});
 await service('feedback_reports','POST',{user_id:a.id,session_id:sid,job_id:jid,rubric_version:'wat-rubric-v1',prompt_version:'synthetic-progress',model_provider:'google_gemini',
  model_name:'synthetic-progress-model',overall_score:score,narrative:summary.narrative,summary,generated_at:time(8)});
 for(const status of ['feedback_queued','feedback_processing',...(state==='processing'?[]:[state==='failed'?'failed':'ready'])])await service('wat_sessions?id=eq.'+sid,'PATCH',{status});
}

test('progress through real local Auth, RLS and API with a fixed analytics clock',async t=>{
 try{
  await t.test('missing authentication is rejected',async()=>{const r=await fetch(api+'/progress',{headers:{apikey:local.ANON_KEY}});assert.equal(r.status,401);assert.equal((await r.json()).error.code,'AUTH_REQUIRED');});
  await t.test('invalid and publishable-key-only authentication is rejected',async()=>{for(const token of ['invalid',local.ANON_KEY]){
   const r=await fetch(api+'/progress',{headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+token}});assert.equal(r.status,401);assert.equal((await r.json()).error.code,'AUTH_INVALID');}});
  const main=await actor(),empty=await actor(),reports=await actor(),bounds=await actor(),dst=await actor(),streak=await actor(),nulls=await actor();
  words=await service('wat_set_items?select=position,word&wat_set_id=eq.7dc73083-f0f1-46a4-ac65-7b7f42a6f9b1&version=eq.1&order=position.asc');assert.equal(words.length,20);
  await t.test('default empty response has exactly the Section 8 fields and fixed generation time',async()=>{
   const d=await data(empty);assert.deepEqual(Object.keys(d).sort(),['range','totals','metrics','weekly_comparison','trends','weak_areas','generated_at'].sort());
   assert.deepEqual(d.range,{key:'30d',from:'2026-02-08T19:00:00.000000Z',to:'2026-03-10T19:00:00.000000Z',timezone:'Asia/Karachi'});
   assert.deepEqual(d.totals,{sessions:0,completed_sessions:0,words_presented:0,answers_recorded:0,reports:0});assert.equal(d.generated_at,'2026-03-10T10:00:00.000000Z');
  });
  await t.test('every documented option is accepted',async()=>{for(const [key,values] of Object.entries({range:['7d','30d','90d','all'],compare:['none','previous_period'],practice_mode:['all','training','simulation'],response_mode:['all','typing','paper']}))for(const value of values)assert.equal((await progress(empty,key+'='+value)).r.status,200);});
  await t.test('unknown, repeated, malformed and unsupported query options are rejected safely',async()=>{
   for(const query of ['range=week','range=','range=%ZZ','range=%2030d','compare=yes','practice_mode=exam','response_mode=pdf','range=7d&range=30d','compare=none&compare=none','practice_mode=all&practice_mode=all','response_mode=all&response_mode=all','answer=PRIVATE-PROGRESS-ANSWER-'+marker]){
    const {r,body}=await progress(empty,query);assert.equal(r.status,422);assert.equal(body.error.code,'VALIDATION_ERROR');assert.ok(!JSON.stringify(body).includes(marker!));}
  });
  await t.test('owner, timezone and test clock inputs cannot influence analytics',async()=>{
   for(const query of ['user_id='+main.id,'timezone=UTC','now=2026-03-10','p_actor='+main.id])assert.equal((await progress(empty,query)).r.status,422);
   const r=await raw('/rest/v1/rpc/qiyadat_progress',{method:'POST',headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+empty.token,'Content-Type':'application/json'},body:JSON.stringify({p_actor:main.id})});assert.equal(r.status,404);
  });
  await t.test('insufficient activity has null timing/scores and empty arrays',async()=>{const d=await data(empty);assert.equal(d.metrics.average_response_seconds,null);assert.equal(d.metrics.average_report_score,null);assert.equal(d.metrics.completion_percent,0);assert.deepEqual(d.trends,[]);assert.deepEqual(d.weak_areas,[]);});
  await session(main,'typed','2026-03-10T05:00:00Z','training','typing',20,18,11250);
  const simulation=await session(main,'sim','2026-03-09T05:00:00Z','simulation','typing',10,8,15000);
  await session(main,'paper','2026-03-08T05:00:00Z','training','paper',20,0,null);
  await session(main,'legacy','2026-03-07T05:00:00Z','simulation','typing',20,20,999999,'legacy_local_storage');
  await session(main,'guest','2026-03-06T05:00:00Z','training','typing',20,20,10000,'guest_local');
  await session(main,'partial','2026-03-10T06:00:00Z','training','typing',2,1,null,'server',true);
  await t.test('partial and completed activity use canonical totals and one-place metrics',async()=>{const d=await data(main);
   assert.deepEqual(d.totals,{sessions:6,completed_sessions:5,words_presented:120,answers_recorded:67,reports:0});assert.equal(d.metrics.completion_percent,76.7);assert.equal(d.metrics.average_response_seconds,11.5);});
  await t.test('typed and paper filters retain legitimate activity without OCR drafts',async()=>{
   assert.equal((await data(main,'response_mode=typing')).totals.sessions,5);const paper=await data(main,'response_mode=paper');assert.equal(paper.totals.sessions,1);assert.equal(paper.totals.answers_recorded,0);assert.equal(paper.metrics.average_response_seconds,null);});
  await t.test('simulation excludes imported timing while retaining its activity',async()=>{const d=await data(main,'practice_mode=simulation');assert.equal(d.totals.sessions,2);assert.equal(d.metrics.average_response_seconds,15);assert.equal(d.trends[0].average_response_seconds,null);});
  await t.test('training and combined filters apply to all metrics and trends',async()=>{const d=await data(main,'practice_mode=training&response_mode=typing');assert.equal(d.totals.sessions,3);assert.equal(d.trends.length,2);assert.equal((await data(main,'practice_mode=simulation&response_mode=paper')).totals.sessions,0);});
  await t.test('trends are completed-only, chronological and preserve null report scores',async()=>{const d=await data(main);assert.deepEqual(d.trends.map((v:any)=>v.date),['2026-03-06','2026-03-07','2026-03-08','2026-03-09','2026-03-10']);assert.ok(d.trends.every((v:any)=>v.report_score===null));assert.equal(d.trends[3].completion_percent,50);});
  await t.test('current streak uses distinct completed local days',async()=>assert.equal((await data(main)).metrics.current_streak_days,5));
  await t.test('request IDs, JSON envelope and private cache are preserved',async()=>{const rid='req_'+randomUUID().replaceAll('-',''),{r,body}=await progress(main,'',{'X-Request-Id':rid});assert.equal(r.headers.get('x-request-id'),rid);assert.equal(r.headers.get('cache-control'),'private, no-store');assert.match(r.headers.get('content-type')!,/application\/json/);assert.deepEqual(Object.keys(body),['data']);});
  for(const [tag,time] of Object.entries({lower7:'2026-03-03T19:00:00Z',before7:'2026-03-03T18:59:59.999Z',lower30:'2026-02-08T19:00:00Z',before30:'2026-02-08T18:59:59.999Z',lower90:'2025-12-10T19:00:00Z',before90:'2025-12-10T18:59:59.999Z',beforeUpper:'2026-03-10T18:59:59.999Z',upper:'2026-03-10T19:00:00Z'}))await session(bounds,tag,time);
  await t.test('7, 30, 90 and all ranges use exact half-open local calendar boundaries',async()=>{for(const [range,count] of Object.entries({'7d':2,'30d':4,'90d':6,all:7}))assert.equal((await data(bounds,'range='+range)).totals.sessions,count);assert.equal((await data(bounds,'range=all')).range.from,'2025-12-10T18:59:59.999000Z');});
  await t.test('Karachi midnight and trend dates are not UTC-midnight dates',async()=>{const d=await data(bounds,'range=7d');assert.equal(d.range.from,'2026-03-03T19:00:00.000000Z');assert.equal(d.trends[0].date,'2026-03-04');});
  await service('profiles?id=eq.'+dst.id,'PATCH',{timezone:'America/New_York'});
  await session(dst,'before-dst','2026-03-04T04:59:59.999Z');await session(dst,'dst','2026-03-04T05:00:00Z');await session(dst,'after-dst','2026-03-11T04:00:00Z');
  await t.test('DST uses independent midnight offsets and a 167-hour seven-day interval',async()=>{const d=await data(dst,'range=7d');assert.equal(d.totals.sessions,1);assert.equal(d.range.from,'2026-03-04T05:00:00.000000Z');assert.equal(d.range.to,'2026-03-11T04:00:00.000000Z');assert.equal(Date.parse(d.range.to)-Date.parse(d.range.from),167*3600000);});
  await t.test('weekly comparison uses windows independent of selected range',async()=>{const d=await data(bounds,'range=7d');assert.equal(d.weekly_comparison.current.sessions,2);assert.equal(d.weekly_comparison.previous.sessions,1);assert.equal(d.weekly_comparison.changes.average_score,null);});
  await t.test('compare none returns explicit null',async()=>assert.equal((await data(main,'compare=none')).weekly_comparison,null));
  const a=await session(reports,'r1','2026-02-28T05:00:00Z');await report(reports,a,4,[weak('LOW_SPECIFICITY'),weak('LOW_CLARITY')]);
  const b=await session(reports,'r2','2026-03-01T05:00:00Z');await report(reports,b,6,[weak('LOW_SPECIFICITY'),weak('LOW_REALISM')]);
  const c=await session(reports,'r3','2026-03-08T05:00:00Z');await report(reports,c,8,[weak('LOW_CLARITY'),weak('LOW_AGENCY'),weak('NEGATIVE_FRAMING')]);
  const d=await session(reports,'r4','2026-03-09T05:00:00Z');await report(reports,d,10,[weak('LOW_CLARITY'),weak('LOW_AGENCY'),weak('LOW_SPECIFICITY','Latest specificity'),weak('LOW_SPECIFICITY','Duplicate ignored'),weak('LOW_REALISM')],'PRACTICAL_RESPONSE_DRILL');
  await report(reports,await session(reports,'processing','2026-03-09T06:00:00Z'),9,[],'ACTOR_ACTION_DRILL','processing');
  await report(reports,await session(reports,'failed','2026-03-09T07:00:00Z'),10,[],'ACTOR_ACTION_DRILL','failed');
  await t.test('ready scores exclude processing/failed jobs and weekly score changes are deterministic',async()=>{const d=await data(reports);assert.equal(d.totals.reports,4);assert.equal(d.totals.completed_sessions,5);assert.equal(d.metrics.average_report_score,7);assert.equal(d.weekly_comparison.current.average_score,9);assert.equal(d.weekly_comparison.previous.average_score,5);assert.equal(d.weekly_comparison.changes.average_score,4);});
  await t.test('weakness recurrence counts once per report and sorts by count then code',async()=>{const w=(await data(reports)).weak_areas;assert.deepEqual(w.map((v:any)=>v.code),['LOW_CLARITY','LOW_SPECIFICITY','LOW_AGENCY','LOW_REALISM']);assert.deepEqual(w.map((v:any)=>v.report_count),[3,3,2,2]);});
  await t.test('weakness directions, most recent label and drill use stored reports only',async()=>{const w=(await data(reports)).weak_areas;assert.equal(w[0].recent_direction,'declining');assert.equal(w[1].recent_direction,'improving');assert.equal(w[3].recent_direction,'stable');assert.equal(w[1].label,'Latest specificity');assert.equal(w[1].recommended_drill,'PRACTICAL_RESPONSE_DRILL');});
  await t.test('mode filters also isolate reports and weaknesses',async()=>{for(const query of ['response_mode=paper','practice_mode=simulation']){const d=await data(reports,query);assert.equal(d.totals.reports,0);assert.deepEqual(d.weak_areas,[]);assert.equal(d.metrics.average_report_score,null);}});
  await t.test('cross-user data never contributes to an empty user RPC or route',async()=>{assert.equal((await data(empty,'range=all')).totals.sessions,0);
   const r=await raw('/rest/v1/rpc/qiyadat_progress',{method:'POST',headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+empty.token,'Content-Type':'application/json'},body:'{}'});assert.equal(r.status,200);assert.equal((await r.json()).totals.reports,0);});
  await report(nulls,await session(nulls,'blank','2026-03-07T05:00:00Z','training','typing',20,0,null),null);
  await t.test('null ready scores and absent timing are never replaced with zero',async()=>{const d=await data(nulls);assert.equal(d.totals.reports,1);assert.equal(d.metrics.average_report_score,null);assert.equal(d.metrics.average_response_seconds,null);assert.equal(d.trends[0].report_score,null);assert.equal(d.metrics.current_streak_days,0);});
  const tie1=await session(streak,'tie1','2026-03-09T05:00:00Z'),tie2=await session(streak,'tie2','2026-03-09T05:00:00Z');
  await session(streak,'streak8','2026-03-08T05:00:00Z');await session(streak,'streak6','2026-03-06T05:00:00Z');
  await t.test('yesterday continues streak, duplicate dates count once and gaps break it',async()=>assert.equal((await data(streak)).metrics.current_streak_days,2));
  await t.test('equal trend timestamps use stable UUID ordering',async()=>{const trends=(await data(streak)).trends;assert.deepEqual(trends.slice(-2).map((v:any)=>v.session_id),[tie1,tie2].sort());});
  await t.test('client elapsed telemetry cannot override authoritative simulation receive time',async()=>{
   await service('wat_responses?session_id=eq.'+simulation+'&position=eq.1','PATCH',{time_used_ms:1000000,client_elapsed_ms:1000000,received_at:'2026-03-09T05:00:01Z'});
   assert.equal((await data(main,'practice_mode=simulation')).metrics.average_response_seconds,13.6);
  });
  await t.test('no raw answers, report narrative, jobs, provider data or identity appear',async()=>{const d=await data(reports);const text=JSON.stringify(d);for(const value of ['PRIVATE-PROGRESS-',marker!,reports.id,'narrative','evidence_positions','session_source','object_path','access_token','job_id','email'])assert.ok(!text.includes(value));});
  await t.test('progress remains readable with normal AI/payment flags disabled',async()=>{const flags=await service('app_settings?select=key,value&key=in.(ocr_enabled,feedback_enabled,payments_enabled,beta_open)');assert.ok(flags.every((v:any)=>v.value===false));assert.equal((await progress(main)).r.status,200);});
 }finally{
  for(const a of actors){await service('feedback_items?user_id=eq.'+a.id,'DELETE');await service('feedback_reports?user_id=eq.'+a.id,'DELETE');
   const r=await raw('/auth/v1/admin/users/'+a.id,{method:'DELETE',headers:secretHeaders});assert.ok(r.ok,'Synthetic progress account and dependent rows removed');}
 }
});
