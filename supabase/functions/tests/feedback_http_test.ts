import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {DISCLAIMER} from '../_shared/feedback/schema.ts';
import {localStatus} from '../../../backend/scripts/local_supabase_cli.ts';
const base='http://127.0.0.1:55321',api=base+'/functions/v1/api/v1';
interface Actor{id:string;token:string}
test('durable feedback through real local API, worker, Auth, RLS and mocked Gemini',async t=>{
 const local=localStatus();
 assert.equal(local.API_URL,base);assert.ok(process.env.QIYADAT_TEST_WORKER_SECRET,'Use npm run test:feedback:http for isolated mock setup.');
 const serviceHeaders={apikey:local.SERVICE_ROLE_KEY,Authorization:'Bearer '+local.SERVICE_ROLE_KEY,'Content-Type':'application/json'};
 const created:string[]=[];const originalSettings=new Map<string,any>();
 async function raw(path:string,options:RequestInit={}){return fetch(base+path,{...options,signal:AbortSignal.timeout(30000)});}
 async function service(path:string,method='GET',body?:unknown){const result=await raw('/rest/v1/'+path,{method,headers:serviceHeaders,...(body===undefined?{}:{body:JSON.stringify(body)})});assert.ok(result.ok,'Synthetic local fixture request succeeds: '+result.status);const text=await result.text();return text?JSON.parse(text):null;}
 async function setting(name:string,value:any){if(!originalSettings.has(name)){const rows=await service('app_settings?key=eq.'+name+'&select=value');originalSettings.set(name,rows[0].value);}await service('app_settings?key=eq.'+name,'PATCH',{value});}
 async function identity():Promise<Actor>{
  const email='qiyadat-phase3-'+randomUUID()+'@example.invalid',password=randomUUID()+randomUUID();
  const response=await raw('/auth/v1/admin/users',{method:'POST',headers:serviceHeaders,body:JSON.stringify({email,password,email_confirm:true,user_metadata:{role:'admin'}})});
  assert.equal(response.status,200);const user=await response.json();created.push(user.id);
  const login=await raw('/auth/v1/token?grant_type=password',{method:'POST',headers:{apikey:local.ANON_KEY,'Content-Type':'application/json'},body:JSON.stringify({email,password})});assert.equal(login.status,200);return {id:user.id,token:(await login.json()).access_token};
 }
 async function call(path:string,actor?:Actor,method='GET',body?:unknown,key?:string,token?:string){
  const response=await fetch(api+path,{method,headers:{apikey:local.ANON_KEY,...(actor?{Authorization:'Bearer '+actor.token}:{}),...(token?{Authorization:'Bearer '+token}:{}),
   ...(body===undefined?{}:{'Content-Type':'application/json'}),...(key?{'Idempotency-Key':key}:{})},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(30000)});
  return {status:response.status,body:await response.json(),headers:response.headers};
 }
 function status(result:any,expected:number,code?:string){assert.equal(result.status,expected,code||'HTTP status');if(code){assert.equal(result.body.error.code,code);assert.equal(result.body.error.request_id,result.headers.get('x-request-id'));}}
 async function consent(actor:Actor){const me=await call('/me',actor);status(await call('/me',actor,'PATCH',{accept_ai_processing_terms_version:me.body.data.ai_processing_consent.version}),200);}
 async function mock(mode:string){const result=await fetch('http://127.0.0.1:'+process.env.QIYADAT_TEST_MOCK_PORT+'/control',{method:'POST',headers:{'Content-Type':'application/json','x-mock-control':process.env.QIYADAT_TEST_MOCK_CONTROL!},body:JSON.stringify({mode})});assert.ok(result.ok);return result.json();}
 async function worker(token=process.env.QIYADAT_TEST_WORKER_SECRET!){const result=await raw('/functions/v1/feedback-worker',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:'{}'});return {status:result.status,body:await result.json()};}
 async function start(actor:Actor,paper=false){const configuration=await call('/config/wat?kind=diagnostic');status(configuration,200);const config=configuration.body.data;const result=await call('/wat/sessions',actor,'POST',{client_session_id:randomUUID(),set_id:config.set.id,set_version:1,kind:'diagnostic',practice_mode:'training',response_mode:paper?'paper':'typing',session_size:20},randomUUID());status(result,201);return result.body.data.id as string;}
 async function finish(actor:Actor,id:string,blank=false){if(!blank)status(await call('/wat/sessions/'+id+'/answers/1',actor,'PUT',{answer:'PRIVATE-ANSWER: A person takes a practical step.'}),200);status(await call('/wat/sessions/'+id+'/finish',actor,'POST',{reason:'manual'},randomUUID()),200);}
 const body={rubric_version:'wat-rubric-v1'};let a:Actor,b:Actor,paid:Actor,free:string,job:string,key:string,report:string;
 try{
  a=await identity();b=await identity();paid=await identity();free=await start(a);
  await t.test('new protected routes reject missing and invalid auth',async()=>{for(const path of ['/wat/sessions/'+free+'/report','/jobs/'+randomUUID()]){status(await call(path),401,'AUTH_REQUIRED');status(await call(path,undefined,'GET',undefined,undefined,'invalid'),401,'AUTH_INVALID');}});
  await t.test('unfinished and foreign sessions use documented errors',async()=>{status(await call('/wat/sessions/'+free+'/report',a,'POST',body,randomUUID()),409,'SESSION_NOT_FINISHED');status(await call('/wat/sessions/'+free+'/report',b,'POST',body,randomUUID()),404,'NOT_FOUND');});
  await finish(a,free);
  await t.test('disabled feedback and missing current consent fail closed',async()=>{status(await call('/wat/sessions/'+free+'/report',a,'POST',body,randomUUID()),503,'FEATURE_DISABLED');await setting('feedback_enabled',true);status(await call('/wat/sessions/'+free+'/report',a,'POST',body,randomUUID()),403,'AI_CONSENT_REQUIRED');await consent(a);});
  await t.test('rubric, unknown fields and idempotency headers are validated',async()=>{for(const invalid of [{rubric_version:'future'},{rubric_version:'wat-rubric-v1',user_id:b.id}])status(await call('/wat/sessions/'+free+'/report',a,'POST',invalid,randomUUID()),422,'VALIDATION_ERROR');status(await call('/wat/sessions/'+free+'/report',a,'POST',body),422,'VALIDATION_ERROR');});
  await t.test('concurrent free report clicks create one job and reservation',async()=>{key=randomUUID();const results=await Promise.all(Array.from({length:4},()=>call('/wat/sessions/'+free+'/report',a,'POST',body,key)));
   results.forEach(r=>{status(r,202);assert.deepEqual(r.body,results[0].body);});job=results[0].body.data.job_id;
   const next=await call('/wat/sessions/'+free+'/report',a,'POST',body,randomUUID());status(next,202);assert.equal(next.body.data.job_id,job);
   assert.equal((await service('usage_reservations?session_id=eq.'+free+'&select=id')).length,1);
   status(await call('/wat/sessions/'+free+'/report',a,'POST',{rubric_version:'future'},key),409,'IDEMPOTENCY_CONFLICT');
  });
  await t.test('job polling is safe and cross-user hidden',async()=>{const result=await call('/jobs/'+job,a);status(result,200);assert.equal(result.body.data.status,'queued');assert.equal(result.body.data.attempt,0);assert.equal(result.body.data.result,null);for(const field of ['locked_by','locked_at','request_id','provider_payload'])assert.ok(!(field in result.body.data));status(await call('/jobs/'+job,b),404,'NOT_FOUND');status(await call('/wat/sessions/'+free+'/report',b),404,'NOT_FOUND');});
  await t.test('worker rejects publishable and candidate tokens',async()=>{assert.equal((await worker(local.ANON_KEY)).status,401);assert.equal((await worker(a.token)).status,401);});
  await t.test('mocked Gemini succeeds with deterministic scores and 20 serialized sentences',async()=>{await mock('valid');assert.equal((await worker()).status,200);const poll=await call('/jobs/'+job,a);status(poll,200);assert.equal(poll.body.data.status,'succeeded');assert.equal(poll.body.data.result.next_action,'view_report');
   const result=await call('/wat/sessions/'+free+'/report',a);status(result,200);report=result.body.data.id;assert.equal(result.body.data.sentences.length,20);assert.equal(result.body.data.score.overall,8);assert.equal(result.body.data.dimensions.clarity.score,8);assert.equal(result.body.data.disclaimer,DISCLAIMER);
   assert.equal(result.body.data.sentences[0].response_source,'typed');assert.equal(result.body.data.sentences[1].ratings,null);assert.equal(result.body.data.sentences[1].score,null);assert.equal(result.body.data.sentences[1].feedback,'No response was recorded.');
   assert.equal(result.headers.get('cache-control'),'private, no-store');assert.deepEqual(Object.keys(result.body.data).sort(),['id','session_id','status','rubric_version','prompt_version','model','generated_at','score','dimensions','sentences','summary','disclaimer'].sort());
  });
  await t.test('same key after completion returns report reference, new key cannot regenerate',async()=>{const replay=await call('/wat/sessions/'+free+'/report',a,'POST',body,key);status(replay,200);assert.equal(replay.body.data.report_id,report);status(await call('/wat/sessions/'+free+'/report',a,'POST',body,randomUUID()),409,'REPORT_ALREADY_EXISTS');});
  await t.test('saved report survives consent withdrawal and disabled feature',async()=>{await service('profile_consents','POST',{user_id:a.id,terms_version:'2026-10-01',accepted:false,accepted_at:new Date().toISOString()});await setting('feedback_enabled',false);status(await call('/wat/sessions/'+free+'/report',a),200);await setting('feedback_enabled',true);});
  await t.test('imported typed feedback requires active entitlement',async()=>{
   await consent(a);const config=(await call('/config/wat?kind=diagnostic')).body.data;
   const imported=await call('/wat/sessions/import',a,'POST',{schema_version:1,client_session_id:randomUUID(),source:'guest_local',set_code:config.set.code,set_version:1,
    kind:'diagnostic',practice_mode:'training',response_mode:'typing',started_at:'2026-10-01T10:00:00Z',completed_at:'2026-10-01T10:05:00Z',ended_early:false,
    responses:config.words.map((word:any)=>({...word,answer:'Synthetic imported response.',completed:true,time_used_ms:1000}))},randomUUID());status(imported,201);
   status(await call('/wat/sessions/'+imported.body.data.id+'/report',a,'POST',body,randomUUID()),403,'ENTITLEMENT_REQUIRED');
  });
  await consent(b);const failureSession=await start(b);await finish(b,failureSession);
  let failureJob:string;
  await t.test('invalid output retries once, then terminal failure releases free quota',async()=>{const result=await call('/wat/sessions/'+failureSession+'/report',b,'POST',body,randomUUID());status(result,202);failureJob=result.body.data.job_id;await mock('invalid');await worker();assert.equal((await call('/jobs/'+failureJob,b)).body.data.status,'retrying');
   await service('processing_jobs?id=eq.'+failureJob,'PATCH',{next_attempt_at:new Date().toISOString()});await worker();const failed=await call('/jobs/'+failureJob,b);assert.equal(failed.body.data.status,'failed');assert.equal(failed.body.data.attempt,2);assert.equal(failed.body.data.error.code,'AI_OUTPUT_INVALID');
   assert.equal((await service('usage_reservations?job_id=eq.'+failureJob+'&select=status'))[0].status,'released');
  });
  await t.test('trusted technical retry uses same free session and succeeds',async()=>{await mock('valid');const retried=await call('/wat/sessions/'+failureSession+'/report',b,'POST',body,randomUUID());status(retried,202);await worker();status(await call('/wat/sessions/'+failureSession+'/report',b),200);const sessions=await service('wat_sessions?user_id=eq.'+b.id+'&is_free_demo=eq.true&select=id');assert.equal(sessions.length,1);assert.equal(sessions[0].id,failureSession);});
  await consent(paid);const begins=new Date(Date.now()-1000),ends=new Date(begins.getTime()+30*86400000);
  await service('entitlements','POST',{user_id:paid.id,type:'founding_30d',starts_at:begins.toISOString(),expires_at:ends.toISOString()});
  await t.test('paid legacy import produces feedback with preserved response source',async()=>{
   const config=(await call('/config/wat?kind=diagnostic')).body.data;
   const imported=await call('/wat/sessions/import',paid,'POST',{schema_version:1,client_session_id:randomUUID(),source:'legacy_local_storage',set_code:config.set.code,set_version:1,
    kind:'diagnostic',practice_mode:'training',response_mode:'typing',started_at:'2026-10-01T10:00:00Z',completed_at:'2026-10-01T10:05:00Z',ended_early:false,
    responses:config.words.map((word:any)=>({...word,answer:'Synthetic imported response.',completed:true,time_used_ms:1000}))},randomUUID());status(imported,201);
   status(await call('/wat/sessions/'+imported.body.data.id+'/report',paid,'POST',body,randomUUID()),202);await worker();
   const report=await call('/wat/sessions/'+imported.body.data.id+'/report',paid);status(report,200);assert.equal(report.body.data.sentences[0].response_source,'legacy_typed');
  });
  const paidSessions:string[]=[];for(let i=0;i<3;i++){const id=await start(paid);await finish(paid,id);paidSessions.push(id);}
  await t.test('concurrent paid reservations enforce three slots with atomic fourth rejection',async()=>{const results=await Promise.all(paidSessions.map(id=>call('/wat/sessions/'+id+'/report',paid,'POST',body,randomUUID())));assert.equal(results.filter(r=>r.status===202).length,2);assert.equal(results.filter(r=>r.body.error?.code==='REPORT_LIMIT_REACHED').length,1);
   assert.equal((await service('usage_reservations?user_id=eq.'+paid.id+'&status=in.(reserved,consumed)&select=id')).length,3);});
  await t.test('paper sessions remain deferred with existing state-conflict code',async()=>{const id=await start(paid,true);status(await call('/wat/sessions/'+id+'/finish',paid,'POST',{reason:'natural'},randomUUID()),200);status(await call('/wat/sessions/'+id+'/report',paid,'POST',body,randomUUID()),409,'SESSION_STATE_CONFLICT');});
  await t.test('browser cannot forge report completion or privileged quota calls',async()=>{const response=await raw('/rest/v1/rpc/qiyadat_feedback_complete',{method:'POST',headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+paid.token,'Content-Type':'application/json'},body:JSON.stringify({p_job:job,p_worker:randomUUID(),p_output:{},p_model_version:'forged'})});assert.ok(response.status>=400);});
 }finally{
  for(const [name,value] of originalSettings)await service('app_settings?key=eq.'+name,'PATCH',{value});
  for(const id of created){
   // Phase 4/privacy workers own production deletion ordering. Test fixtures
   // remove report children first because their response FK is intentionally restrictive.
   await service('feedback_items?user_id=eq.'+id,'DELETE');
   await service('feedback_reports?user_id=eq.'+id,'DELETE');
   const response=await raw('/auth/v1/admin/users/'+id,{method:'DELETE',headers:serviceHeaders});assert.ok(response.ok,'Synthetic Auth fixture cleanup succeeds');
  }
 }
});
