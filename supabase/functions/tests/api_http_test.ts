/** Real local Edge Function + Supabase Auth/PostgREST tests. Never use hosted URLs. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
const base='http://127.0.0.1:55321';
const api=base+'/functions/v1/api/v1';
function localKeys(){
 let config:any;
 try {config=JSON.parse(execFileSync(process.execPath,[join(process.env.USERPROFILE!,'node_modules','supabase','dist','supabase.js'),'status','--output','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:30000}));}
 catch {throw new Error('Local Supabase status is unavailable. Start the installed local stack first.');}
 if(config.API_URL!==base || !config.ANON_KEY || !config.SERVICE_ROLE_KEY) throw new Error('Expected local Supabase keys at 127.0.0.1:55321. Hosted testing is prohibited.');
 return {anon:config.ANON_KEY as string,service:config.SERVICE_ROLE_KEY as string};
}
interface Actor {id:string;token:string}
function directPreflight(origin:string,method:string,requestHeaders=''){
 const request=['OPTIONS /api/v1/me HTTP/1.1','Host: edge_runtime','Origin: '+origin,
  'Access-Control-Request-Method: '+method,...(requestHeaders?['Access-Control-Request-Headers: '+requestHeaders]:[]),'Connection: close','',''].join('\r\n');
 const script=`(printf '%s' '${request}'; sleep 2) | nc -w 10 edge_runtime 8081`;
 const raw=execFileSync('docker',['exec','supabase_kong_qiyadat-local','sh','-c',script],{encoding:'utf8',timeout:15000});
 const [head,body='']=raw.split(/\r?\n\r?\n/,2),lines=head.split(/\r?\n/),match=/^HTTP\/\d(?:\.\d)?\s+(\d{3})/.exec(lines.shift()!);
 assert.ok(match,'Direct Edge Runtime returned an HTTP response');const headers=new Headers();
 for(const line of lines){const colon=line.indexOf(':');if(colon>0)headers.append(line.slice(0,colon).trim(),line.slice(colon+1).trim());}
 return {status:Number(match[1]),body:body?JSON.parse(body):null,headers};
}
test('real local Edge Function authenticated lifecycle',async t=>{
 const keys=localKeys(),created:string[]=[];
 async function raw(path:string,options:RequestInit={}){return fetch(base+path,{...options,signal:AbortSignal.timeout(20000)});}
 async function identity():Promise<Actor>{
  const email='qiyadat-phase2-'+randomUUID()+'@example.invalid',password=randomUUID()+randomUUID();
  const response=await raw('/auth/v1/admin/users',{method:'POST',headers:{apikey:keys.service,Authorization:'Bearer '+keys.service,'Content-Type':'application/json'},body:JSON.stringify({email,password,email_confirm:true,user_metadata:{role:'admin',is_admin:true}})});
  assert.equal(response.status,200,'Synthetic local auth user can be created');
  const user=await response.json();created.push(user.id);
  const login=await raw('/auth/v1/token?grant_type=password',{method:'POST',headers:{apikey:keys.anon,'Content-Type':'application/json'},body:JSON.stringify({email,password})});
  assert.equal(login.status,200,'Synthetic local Auth login succeeds');const session=await login.json();
  assert.equal(typeof session.access_token,'string');return {id:user.id,token:session.access_token};
 }
 async function call(path:string,{actor,method='GET',body,key,headers={}}:{actor?:Actor;method?:string;body?:unknown;key?:string;headers?:Record<string,string>}={}){
  const response=await fetch(api+path,{method,headers:{apikey:keys.anon,...(actor?{Authorization:'Bearer '+actor.token}:{}),...(body!==undefined?{'Content-Type':'application/json'}:{}),...(key?{'Idempotency-Key':key}:{}),...headers},...(body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}),signal:AbortSignal.timeout(20000)});
  let value:any=null;if(response.status!==204&&response.status!==304) {try {value=await response.json();}catch{throw new Error('Local Edge Function did not return JSON. Serve functions api first.');}}
  return {status:response.status,body:value,headers:response.headers};
 }
 function status(result:any,expected:number,code?:string){assert.equal(result.status,expected,code??'HTTP status');if(code)assert.equal(result.body?.error?.code,code);}
 const key=()=>randomUUID();
 let a:Actor,b:Actor,c:Actor,config:any,start:any,sid:string,finish:any,importBody:any;
 try {
  await t.test('public health, configuration, cache and request IDs',async()=>{
   const health=await call('/health',{headers:{'X-Request-Id':'req_0123456789abcdef0123456789abcdef'}});status(health,200);assert.equal(health.body.data.database,'up');assert.equal(health.headers.get('X-Request-Id'),'req_0123456789abcdef0123456789abcdef');
   config=await call('/config/wat?kind=diagnostic');status(config,200);assert.equal(config.body.data.words.length,20);assert.deepEqual(config.body.data.rules,{total_words:20,seconds_per_word:15,answer_grace_ms:2000,answer_max_chars:280});
   assert.match(config.headers.get('Cache-Control')!,/public/);status(await call('/config/wat?kind=diagnostic',{headers:{'If-None-Match':config.headers.get('ETag')!}}),304);
   status(await call('/config/wat?kind=practice'),503,'FEATURE_DISABLED');status(await call('/not-a-route'),404,'NOT_FOUND');
  });
  await t.test('missing, invalid and publishable-key-only auth is rejected',async()=>{
   status(await call('/me'),401,'AUTH_REQUIRED');status(await call('/me',{headers:{Authorization:'Bearer invalid'}}),401,'AUTH_INVALID');status(await call('/me',{headers:{Authorization:'Bearer '+keys.anon}}),401,'AUTH_INVALID');
  });
  await t.test('CORS is allowlisted and preflight validates required headers',async()=>{
   // The local CLI's Kong route installs a wildcard CORS plugin, so probe the served
   // function directly over Docker's existing network to verify our own allowlist.
   const preflight=directPreflight('http://127.0.0.1:8080','PATCH','authorization,apikey,content-type,x-request-id');status(preflight,204);assert.equal(preflight.headers.get('Access-Control-Allow-Origin'),'http://127.0.0.1:8080');
   const bad=directPreflight('https://untrusted.example.invalid','GET');status(bad,403,'FORBIDDEN');assert.equal(bad.headers.get('Access-Control-Allow-Origin'),null);
  });
  a=await identity();b=await identity();c=await identity();
  await t.test('Auth creates candidate account and GET me uses canonical private response',async()=>{
   const me=await call('/me',{actor:a});status(me,200);assert.equal(me.body.data.id,a.id);assert.equal(me.body.data.role,'candidate');assert.equal(me.body.data.free_demo.status,'available');assert.equal(me.headers.get('Cache-Control'),'private, no-store');assert.equal(me.body.data.usage.free_demo_sessions_remaining_lifetime,1);
  });
  await t.test('safe PATCH and current consent; protected fields and invalid values rejected',async()=>{
   const me=await call('/me',{actor:a});const version=me.body.data.ai_processing_consent.version;
   const patched=await call('/me',{actor:a,method:'PATCH',body:{display_name:' Local Candidate ',timezone:'Asia/Karachi',accept_ai_processing_terms_version:version}});status(patched,200);assert.equal(patched.body.data.display_name,'Local Candidate');assert.equal(patched.body.data.ai_processing_consent.accepted,true);
   for(const body of [{role:'admin'},{email:'other@example.invalid'},{entitlement:'founding_30d'},{quota:999},{display_name:'   '},{display_name:'x'.repeat(81)},{timezone:'Mars/Olympus'},{accept_ai_processing_terms_version:'future'}]) status(await call('/me',{actor:a,method:'PATCH',body}),422,'VALIDATION_ERROR');
   status(await call('/me',{actor:a,method:'PATCH',body:'{'}),400,'INVALID_JSON');
  });
  const startBody=(client:string,mode='training',response='typing')=>({client_session_id:client,set_id:config.body.data.set.id,set_version:config.body.data.set.version,kind:'diagnostic',practice_mode:mode,response_mode:response,session_size:20});
  await t.test('start validates idempotency, config, size, mode and unknown properties',async()=>{
   status(await call('/wat/sessions',{actor:a,method:'POST',body:startBody('missing-key')}),422,'VALIDATION_ERROR');
   status(await call('/wat/sessions',{actor:a,method:'POST',key:key(),body:{...startBody('stale'),set_version:999}}),409,'CONFIG_VERSION_MISMATCH');
   for(const body of [{...startBody('bad'),session_size:10},{...startBody('bad'),practice_mode:'fake'},{...startBody('bad'),user_id:b.id}])status(await call('/wat/sessions',{actor:a,method:'POST',key:key(),body}),422,'VALIDATION_ERROR');
  });
  await t.test('eight concurrent identical starts yield one resource and exact replay',async()=>{
   const idempotency=key(),body=startBody('training-'+randomUUID());
   const results=await Promise.all(Array.from({length:8},()=>call('/wat/sessions',{actor:a,method:'POST',key:idempotency,body})));
   for(const r of results){status(r,201);assert.deepEqual(r.body,results[0].body);}start=results[0];sid=start.body.data.id;
   assert.equal(start.body.data.resumed,false);assert.equal(start.body.data.items.length,20);assert.deepEqual(start.body.data.items.map((i:any)=>i.word),config.body.data.words.map((i:any)=>i.word));
   assert.equal(new Date(start.body.data.expires_at).getTime()-new Date(start.body.data.started_at).getTime(),1800000);
   status(await call('/wat/sessions',{actor:a,method:'POST',key:idempotency,body:{...body,client_session_id:'conflict'}}),409,'IDEMPOTENCY_CONFLICT');
  });
  await t.test('free diagnostic resumes original session across device and requested mode',async()=>{
   const resumed=await call('/wat/sessions',{actor:a,method:'POST',key:key(),body:startBody('new-device','simulation','paper')});status(resumed,200);assert.equal(resumed.body.data.id,sid);assert.equal(resumed.body.data.resumed,true);assert.equal(resumed.body.data.practice_mode,'training');
  });
  await t.test('cross-user detail, answer, and finish return 404',async()=>{
   status(await call('/wat/sessions/'+sid,{actor:b}),404,'NOT_FOUND');
   status(await call('/wat/sessions/'+sid+'/answers/1',{actor:b,method:'PUT',body:{answer:'Other user'}}),404,'NOT_FOUND');
   status(await call('/wat/sessions/'+sid+'/finish',{actor:b,method:'POST',key:key(),body:{reason:'manual'}}),404,'NOT_FOUND');
   const history=await call('/wat/sessions',{actor:b});status(history,200);assert.equal(history.body.data.length,0);
  });
  await t.test('answer boundaries, NFC/LF, blanks, and training replacements',async()=>{
   const save=(position:number,answer:string)=>call('/wat/sessions/'+sid+'/answers/'+position,{actor:a,method:'PUT',body:{answer,client_elapsed_ms:1000,advance_reason:'autosave'}});
   status(await save(0,'x'),422,'VALIDATION_ERROR');status(await save(21,'x'),422,'VALIDATION_ERROR');
   status(await save(1,'😀'.repeat(280)),200);status(await save(1,'😀'.repeat(281)),422,'VALIDATION_ERROR');
   const normalized=await save(1,'e\u0301\r\nNext');status(normalized,200);assert.equal(normalized.body.data.answer,'é\nNext');assert.equal(normalized.body.data.locked,false);
   status(await save(20,''),200);const replaced=await save(1,'Replacement');status(replaced,200);assert.equal(replaced.body.data.answer,'Replacement');
  });
  await t.test('detail exposes ordered snapshot and no storage/provider data',async()=>{
   const detail=await call('/wat/sessions/'+sid,{actor:a});status(detail,200);assert.equal(detail.body.data.responses.length,20);assert.equal(detail.body.data.timing_trust,'server_verified');assert.equal(detail.body.data.responses[0].answer,'Replacement');
   for(const field of ['object_path','provider_response','deleted_images','storage_path'])assert.ok(!JSON.stringify(detail.body).includes(field));
  });
  await t.test('four concurrent finish requests return exact result and safe statistics',async()=>{
   const idem=key();const results=await Promise.all(Array.from({length:4},()=>call('/wat/sessions/'+sid+'/finish',{actor:a,method:'POST',key:idem,body:{reason:'manual'}})));
   for(const r of results){status(r,200);assert.deepEqual(r.body,results[0].body);}finish=results[0];assert.equal(finish.body.data.status,'finished');assert.equal(finish.body.data.next_action,'generate_report');assert.equal(finish.body.data.ended_early,true);
   assert.deepEqual(finish.body.data.statistics,{total_words:20,completed_words:2,answered_words:1,blank_words:19,average_response_seconds:1});
   status(await call('/wat/sessions/'+sid+'/answers/1',{actor:a,method:'PUT',body:{answer:'After finish'}}),409,'SESSION_ALREADY_FINISHED');
   status(await call('/wat/sessions/'+sid+'/finish',{actor:a,method:'POST',key:key(),body:{reason:'manual'}}),409,'SESSION_ALREADY_FINISHED');
   status(await call('/wat/sessions',{actor:a,method:'POST',key:key(),body:startBody('second-free')}),403,'DIAGNOSTIC_ALREADY_USED');
  });
  await t.test('guest import exact concurrent replay and client-session deduplication',async()=>{
   importBody={schema_version:1,client_session_id:'guest-'+randomUUID(),source:'guest_local',set_code:config.body.data.set.code,set_version:config.body.data.set.version,kind:'diagnostic',practice_mode:'training',response_mode:'typing',started_at:'2026-10-01T10:00:00Z',completed_at:'2026-10-01T10:05:00Z',ended_early:false,responses:config.body.data.words.map((w:any)=>({...w,answer:'Synthetic import.',completed:true,time_used_ms:1000}))};
   const idem=key(),results=await Promise.all(Array.from({length:3},()=>call('/wat/sessions/import',{actor:a,method:'POST',key:idem,body:importBody})));
   for(const r of results){status(r,201);assert.deepEqual(r.body,results[0].body);}assert.equal(results[0].body.data.timing_trust,'client_reported');assert.equal(results[0].body.data.eligible_for_feedback,false);
   const duplicate=await call('/wat/sessions/import',{actor:a,method:'POST',key:key(),body:importBody});status(duplicate,200);assert.equal(duplicate.body.data.id,results[0].body.data.id);
  });
  await t.test('imports validate immutable words, 20 unique positions and chronology',async()=>{
   for(const body of [{...importBody,client_session_id:randomUUID(),responses:importBody.responses.slice(1)},{...importBody,client_session_id:randomUUID(),responses:importBody.responses.map((r:any,i:number)=>i===0?{...r,position:2}:r)},{...importBody,client_session_id:randomUUID(),completed_at:'2026-09-01T00:00:00Z'}])status(await call('/wat/sessions/import',{actor:a,method:'POST',key:key(),body}),422,'VALIDATION_ERROR');
   status(await call('/wat/sessions/import',{actor:a,method:'POST',key:key(),body:{...importBody,client_session_id:randomUUID(),responses:importBody.responses.map((r:any,i:number)=>i===0?{...r,word:'WRONG'}:r)}}),409,'CONFIG_VERSION_MISMATCH');
  });
  await t.test('legacy and empty paper imports retain activity-only timing and eligibility',async()=>{
   const legacy=await call('/wat/sessions/import',{actor:a,method:'POST',key:key(),body:{...importBody,client_session_id:randomUUID(),source:'legacy_local_storage'}});status(legacy,201);
   const detail=await call('/wat/sessions/'+legacy.body.data.id,{actor:a});assert.equal(detail.body.data.responses[0].source,'legacy_typed');
   const paper=await call('/wat/sessions/import',{actor:a,method:'POST',key:key(),body:{...importBody,client_session_id:randomUUID(),response_mode:'paper',responses:importBody.responses.map((r:any)=>({...r,answer:''}))}});status(paper,201);assert.equal(paper.body.data.eligible_for_feedback,false);
  });
  await t.test('history filters, stable cursor pages, owner binding, malformed cursor and limits',async()=>{
   const first=await call('/wat/sessions?limit=1',{actor:a});status(first,200);assert.equal(first.body.data.length,1);assert.equal(first.body.meta.has_more,true);assert.ok(!('responses'in first.body.data[0]));
   const cursor=first.body.meta.next_cursor,next=await call('/wat/sessions?limit=1&cursor='+encodeURIComponent(cursor),{actor:a});status(next,200);assert.notEqual(next.body.data[0].id,first.body.data[0].id);
   status(await call('/wat/sessions?limit=1&cursor='+encodeURIComponent(cursor),{actor:b}),422,'VALIDATION_ERROR');status(await call('/wat/sessions?cursor=bad',{actor:a}),422,'VALIDATION_ERROR');status(await call('/wat/sessions?limit=101',{actor:a}),422,'VALIDATION_ERROR');
   const filtered=await call('/wat/sessions?status=finished&kind=diagnostic&practice_mode=training&response_mode=typing&from=2026-01-01T00%3A00%3A00Z',{actor:a});status(filtered,200);assert.ok(filtered.body.data.every((r:any)=>r.status==='finished'&&r.response_mode==='typing'));
  });
  await t.test('simulation early and locked answers; manual missing positions',async()=>{
   const result=await call('/wat/sessions',{actor:c,method:'POST',key:key(),body:startBody('sim-'+randomUUID(),'simulation')});status(result,201);const id=result.body.data.id;
   status(await call('/wat/sessions/'+id+'/answers/2',{actor:c,method:'PUT',body:{answer:'early',client_saved_at:'2099-01-01T00:00:00Z'}}),409,'ANSWER_NOT_ACTIVE');
   const saved=await call('/wat/sessions/'+id+'/answers/1',{actor:c,method:'PUT',body:{answer:'First'}});status(saved,200);assert.equal(saved.body.data.locked,true);
   status(await call('/wat/sessions/'+id+'/answers/1',{actor:c,method:'PUT',body:{answer:'Replace'}}),409,'ANSWER_ALREADY_LOCKED');
   const ended=await call('/wat/sessions/'+id+'/finish',{actor:c,method:'POST',key:key(),body:{reason:'manual'}});status(ended,200);assert.equal(ended.body.data.ended_early,true);
  });
  await t.test('paper start rejects typed writes and finishes awaiting upload',async()=>{
   const result=await call('/wat/sessions',{actor:b,method:'POST',key:key(),body:startBody('paper-'+randomUUID(),'training','paper')});status(result,201);const id=result.body.data.id;
   status(await call('/wat/sessions/'+id+'/answers/1',{actor:b,method:'PUT',body:{answer:'Not allowed'}}),409,'SESSION_STATE_CONFLICT');
   const ended=await call('/wat/sessions/'+id+'/finish',{actor:b,method:'POST',key:key(),body:{reason:'natural'}});status(ended,200);assert.equal(ended.body.data.status,'awaiting_upload');assert.equal(ended.body.data.next_action,'upload_paper_pages');
  });
  await t.test('browser cannot call service RPC or grant an entitlement directly',async()=>{
   const headers={apikey:keys.anon,Authorization:'Bearer '+a.token,'Content-Type':'application/json'};
   const denied=await raw('/rest/v1/rpc/qiyadat_mutate',{method:'POST',headers,body:JSON.stringify({p_actor:a.id,p_operation:'profile',p_body:{role:'admin'}})});assert.ok(denied.status>=400);
   const entitlement=await raw('/rest/v1/entitlements',{method:'POST',headers,body:JSON.stringify({user_id:a.id,type:'beta'})});assert.ok(entitlement.status>=400);
   const me=await call('/me',{actor:a});status(me,200);assert.equal(me.body.data.role,'candidate');assert.equal(me.body.data.usage.reports_used_rolling_24h,0);assert.equal(me.body.data.usage.free_demo_sessions_used_lifetime,1);
  });
 } finally {
  for(const id of created){const response=await raw('/auth/v1/admin/users/'+id,{method:'DELETE',headers:{apikey:keys.service,Authorization:'Bearer '+keys.service}});assert.ok(response.ok,'Synthetic Auth fixture cleanup succeeds');}
 }
});
