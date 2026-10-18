import test from 'node:test';
import assert from 'node:assert/strict';
import {progressQuery,readProgress} from '../_shared/progress.ts';
import {ApiError} from '../_shared/errors.ts';
import {createApp} from '../_shared/router.ts';
import {readEnvironment} from '../_shared/env.ts';
const url=(query='')=>new URL('http://local.invalid/functions/v1/api/v1/progress'+(query?'?'+query:''));
const defaults={p_range:'30d',p_compare:'previous_period',p_practice_mode:'all',p_response_mode:'all'};
const invalid=(error:any)=>error instanceof ApiError&&error.code==='VALIDATION_ERROR';
test('progress query defaults match Section 8',()=>assert.deepEqual(progressQuery(url()),defaults));
for(const [field,values] of Object.entries({range:['7d','30d','90d','all'],compare:['none','previous_period'],practice_mode:['all','training','simulation'],response_mode:['all','typing','paper']})){
 test('progress accepts every '+field+' value',()=>{for(const value of values)assert.equal(progressQuery(url(field+'='+value))['p_'+field as keyof typeof defaults],value);});
}
for(const query of ['range=','range=365d','range=7D','compare=previous_week','practice_mode=exam','response_mode=pdf','range=7d&range=30d',
 'compare=none&compare=none','practice_mode=training&practice_mode=simulation','response_mode=paper&response_mode=paper','user_id=PRIVATE-USER','at=2026-03-10','timezone=UTC','range=%ZZ','range=%2030d']){
 test('progress rejects invalid query '+query.split('=')[0]+' '+query.length,()=>assert.throws(()=>progressQuery(url(query)),invalid));
}
test('progress forwards one user-scoped RPC without actor or clock',async()=>{
 const calls:any[]=[];const result={generated_at:'2026-03-10T10:00:00Z'};
 const context:any={id:'private-other-user',client:{rpc:async(...args:any[])=>{calls.push(args);return result;}}};
 assert.equal(await readProgress(url('range=7d&compare=none&practice_mode=training&response_mode=paper'),context),result);
 assert.deepEqual(calls,[['qiyadat_progress',{p_range:'7d',p_compare:'none',p_practice_mode:'training',p_response_mode:'paper'}]]);
});
const env=readEnvironment(k=>({SUPABASE_URL:'http://local.invalid',SUPABASE_ANON_KEY:'synthetic-public',SUPABASE_SERVICE_ROLE_KEY:'synthetic-service'} as Record<string,string>)[k]);
const actor='00000000-0000-4000-8000-000000000001';
const data={range:{key:'30d',from:'2026-02-08T19:00:00Z',to:'2026-03-10T19:00:00Z',timezone:'Asia/Karachi'},
 totals:{sessions:0,completed_sessions:0,words_presented:0,answers_recorded:0,reports:0},
 metrics:{completion_percent:0,average_response_seconds:null,average_report_score:null,current_streak_days:0},
 weekly_comparison:null,trends:[],weak_areas:[],generated_at:'2026-03-10T10:00:00Z'};
function setup(fail=false){const logs:string[]=[],calls:any[]=[];
 const fetcher:typeof fetch=async(input:any,options:any)=>{const path=new URL(String(input)).pathname;
  if(path==='/auth/v1/user')return options.headers.get('authorization')==='Bearer synthetic-user'?Response.json({id:actor,email:'PRIVATE-EMAIL@example.invalid'}):Response.json({message:'PRIVATE-AUTH'},{status:401});
  if(path==='/rest/v1/profiles')return Response.json([{id:actor,timezone:'Asia/Karachi'}]);
  if(path.endsWith('/qiyadat_account_context'))return Response.json({});
  if(path.endsWith('/qiyadat_progress')){calls.push({headers:Object.fromEntries(options.headers),body:JSON.parse(options.body)});
   if(fail)return Response.json({message:'PRIVATE-ANSWER PRIVATE-OCR PRIVATE-REPORT PRIVATE-SECRET'},{status:503});return Response.json(data);}
  throw new Error('Unexpected test dependency');
 };return {app:createApp(env,{fetcher,sink:line=>logs.push(line)}),logs,calls};
}
const headers={authorization:'Bearer synthetic-user',apikey:'synthetic-public'};
test('progress route uses success envelope, fixed clock data, private cache and propagated request ID',async()=>{
 const {app,calls}=setup(),rid='req_'+actor.replaceAll('-','');
 const response=await app(new Request(url(),{headers:{...headers,'x-request-id':rid}}));
 assert.equal(response.status,200);assert.deepEqual(await response.json(),{data});assert.equal(response.headers.get('cache-control'),'private, no-store');
 assert.equal(response.headers.get('x-request-id'),rid);assert.match(response.headers.get('content-type')!,/application\/json/);
 assert.equal(calls.length,1);assert.deepEqual(calls[0].body,defaults);assert.equal(calls[0].headers.authorization,'Bearer synthetic-user');
 assert.equal(calls[0].headers.apikey,'synthetic-public');
});
test('progress route requires real user authentication',async()=>{
 for(const authorization of [undefined,'Bearer invalid','Bearer synthetic-public','Bearer synthetic-service']){
  const {app,calls}=setup(),response=await app(new Request(url(),{headers:{apikey:'synthetic-public',...(authorization?{authorization}:{})}}));
  assert.equal(response.status,401);assert.equal((await response.json()).error.code,authorization?'AUTH_INVALID':'AUTH_REQUIRED');assert.equal(calls.length,0);
 }
});
test('progress route rejects a supplied owner before analytics access',async()=>{
 const {app,calls}=setup();const response=await app(new Request(url('user_id='+actor),{headers}));assert.equal(response.status,422);
 const body=await response.json();assert.equal(body.error.code,'VALIDATION_ERROR');assert.equal(body.error.request_id,response.headers.get('x-request-id'));assert.equal(calls.length,0);
});
test('progress dependency failures map to the documented safe internal error',async()=>{
 const {app,logs}=setup(true),response=await app(new Request(url(),{headers}));assert.equal(response.status,500);
 const body=await response.json();assert.equal(body.error.code,'INTERNAL_ERROR');assert.ok(!JSON.stringify(body).includes('PRIVATE-'));
 assert.ok(!logs.join('').includes('PRIVATE-'));
});
test('progress logs contain neither private data, credentials nor raw query values',async()=>{
 const {app,logs}=setup();await app(new Request(url(),{headers}));await app(new Request(url('answer=PRIVATE-ANSWER&ocr=PRIVATE-OCR&report=PRIVATE-REPORT'),{headers}));
 const output=logs.join('');for(const value of ['PRIVATE-','synthetic-user','synthetic-service','example.invalid','?answer'])assert.ok(!output.includes(value));
 assert.equal(JSON.parse(logs[0]).route,'progress');
});
test('progress preflight permits only GET with the configured exact local origin',async()=>{
 const {app}=setup();const response=await app(new Request(url(),{method:'OPTIONS',headers:{origin:'http://localhost:8080','access-control-request-method':'GET','access-control-request-headers':'Authorization,apikey,X-Request-Id'}}));
 assert.equal(response.status,204);assert.equal(response.headers.get('access-control-allow-origin'),'http://localhost:8080');
});
