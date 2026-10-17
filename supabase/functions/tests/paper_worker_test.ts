import test from 'node:test';
import assert from 'node:assert/strict';
import {processOcr,createPaperWorker} from '../_shared/paper/worker.ts';
import {VisionFailure} from '../_shared/paper/vision.ts';
import {ApiError} from '../_shared/errors.ts';
import {imageRecord,imageBytes} from './paper_fixtures.ts';
const words=Array.from({length:20},(_,i)=>({position:i+1,word:'Word '+(i+1)}));
async function fixture(change:(name:string,body:any)=>any=()=>undefined){const image=await imageRecord(),calls:any[]=[];
 const job={id:crypto.randomUUID(),request_id:crypto.randomUUID(),words,pages:[image]};
 const service={rpc:async(name:string,body:any)=>{calls.push({name,body});const value=change(name,body);return value!==undefined?value:name==='qiyadat_ocr_claim'?job:true;}} as any;
 const storage={download:async()=>imageBytes()} as any;
 return {service,storage,calls,job,image};
}
test('OCR worker recovers, claims, validates bytes and commits a twenty-row draft',async()=>{
 const f=await fixture();let requests=0;
 await processOcr(f.service,f.storage,{recognize:async(_bytes,_request,accepted)=>{requests++;await accepted();return [{text:'1. PRIVATE-OCR text',confidence:0.9}];}});
 assert.equal(requests,1);assert.deepEqual(f.calls.slice(0,2).map(c=>c.name),['qiyadat_ocr_recover','qiyadat_ocr_claim']);
 const complete=f.calls.find(c=>c.name==='qiyadat_ocr_complete');assert.equal(complete.body.p_draft.length,20);assert.equal(complete.body.p_draft[0].ocr_text,'PRIVATE-OCR text');
 assert.deepEqual(f.calls.filter(c=>c.name==='qiyadat_ocr_page_event').map(c=>c.body.p_event),['dispatch','accepted','done']);
});
test('completed page checkpoint is reused across a later page retry',async()=>{
 const f=await fixture();f.job.pages[0].lines=[{text:'1. Earlier page',confidence:0.9}] as any;let requests=0;
 await processOcr(f.service,f.storage,{recognize:async()=>{requests++;return [];}});assert.equal(requests,0);assert.ok(f.calls.some(c=>c.name==='qiyadat_ocr_complete'));
});
test('lost completion acknowledgement retries the same draft without another provider request',async()=>{
 let acknowledgements=0;const f=await fixture(name=>{if(name==='qiyadat_ocr_complete'&&++acknowledgements===1)throw new ApiError('PROVIDER_UNAVAILABLE');});let requests=0;
 await processOcr(f.service,f.storage,{recognize:async(_b,_r,accepted)=>{requests++;await accepted();return [];}});assert.equal(requests,1);assert.equal(acknowledgements,2);
});
test('invalid private bytes never reach provider and fail terminally',async()=>{
 const f=await fixture();f.storage.download=async()=>new Uint8Array([1,2,3]);let requests=0;
 await processOcr(f.service,f.storage,{recognize:async()=>{requests++;return [];}});assert.equal(requests,0);assert.equal(f.calls.at(-1).name,'qiyadat_ocr_fail');assert.equal(f.calls.at(-1).body.p_retryable,false);
});
test('transient Vision failure schedules a safe retry',async()=>{
 const f=await fixture();await processOcr(f.service,f.storage,{recognize:async()=>{throw new VisionFailure('PROVIDER_UNAVAILABLE',true);}});
 const fail=f.calls.at(-1);assert.equal(fail.body.p_code,'PROVIDER_UNAVAILABLE');assert.equal(fail.body.p_retryable,true);assert.ok(!JSON.stringify(fail.body).includes('PRIVATE'));
});
test('feature or account revocation at dispatch prevents a provider call',async()=>{
 const f=await fixture(name=>{if(name==='qiyadat_ocr_page_event')throw new ApiError('FEATURE_DISABLED');});let requests=0;
 await processOcr(f.service,f.storage,{recognize:async()=>{requests++;return [];}});assert.equal(requests,0);assert.equal(f.calls.at(-1).body.p_code,'FEATURE_DISABLED');
});
test('OAuth authorization failure never marks a Vision page dispatched',async()=>{
 const f=await fixture();await processOcr(f.service,f.storage,{authorize:async()=>{throw new VisionFailure('PROVIDER_UNAVAILABLE',false);},recognize:async()=>{throw new Error('must not call');}});
 assert.ok(!f.calls.some(c=>c.name==='qiyadat_ocr_page_event'));assert.equal(f.calls.at(-1).body.p_retryable,false);
});
test('disabled processing reports FEATURE_DISABLED without calling a provider',async()=>{
 const f=await fixture(name=>name==='qiyadat_ocr_claim'?null:name==='qiyadat_ocr_enabled'?false:undefined);
 await assert.rejects(processOcr(f.service,f.storage,{recognize:async()=>{throw new Error('must not call');}}),e=>e instanceof ApiError&&e.code==='FEATURE_DISABLED');
});
test('empty durable queue makes no provider request',async()=>{const f=await fixture(name=>name==='qiyadat_ocr_claim'?null:undefined);await processOcr(f.service,f.storage,{recognize:async()=>{throw new Error('must not call');}});assert.equal(f.calls.length,3);});
test('worker rejects user/public auth and forged body without logging sensitive content',async()=>{
 const logs:string[]=[],env={url:'http://local',serviceKey:'synthetic-service',publishableKey:'synthetic-public',origins:new Set<string>(),release:'test'};
 const secret='synthetic-internal-worker-secret-32',handler=createPaperWorker(env,secret,{sink:line=>logs.push(line),fetcher:async()=>Response.json(null)});
 for(const token of ['',env.publishableKey,'PRIVATE-JWT']){const r=await handler(new Request('http://local/ocr-worker',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:'{}'}));assert.equal(r.status,401);}
 const r=await handler(new Request('http://local/ocr-worker',{method:'POST',headers:{Authorization:'Bearer '+secret,'Content-Type':'application/json'},body:'{"ocr_text":"PRIVATE-OCR"}'}));assert.equal(r.status,422);
 assert.ok(!logs.join('').includes('PRIVATE'));assert.ok(!logs.join('').includes(secret));
});
