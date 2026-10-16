import test from 'node:test';
import assert from 'node:assert/strict';
import {createWorker,processFeedback} from '../_shared/feedback/worker.ts';
import {SupabaseClient} from '../_shared/clients.ts';
import {ApiError} from '../_shared/errors.ts';
import {responses,validFeedback} from './feedback_fixtures.ts';
const config={apiKey:'synthetic',model:'synthetic-model',promptVersion:'synthetic-prompt',timeoutMs:100,workerSecret:'synthetic-long-secret-for-worker-auth',endpoint:'http://127.0.0.1'};
const env={url:'http://local.invalid',publishableKey:'synthetic-public',serviceKey:'synthetic-service',origins:new Set<string>(),release:'test'};
const job={id:'00000000-0000-0000-0000-000000000001',model:config.model,request_id:'safe-correlation',responses:responses()};
function client(handler:(name:string,body:any)=>any){return new SupabaseClient(env.url,env.serviceKey,undefined,async(url,options)=>Response.json(await handler(String(url).split('/').pop()!,JSON.parse(String(options?.body)||'{}'))));}
test('worker recovers, claims, authorizes and commits without provider call in a transaction',async()=>{const calls:string[]=[];const service=client(name=>{calls.push(name);return name.endsWith('claim')?job:true;});let generated=0;
 await processFeedback(service,{generate:async()=>{generated++;assert.deepEqual(calls,['qiyadat_feedback_recover','qiyadat_feedback_claim','qiyadat_feedback_authorize']);return {output:validFeedback(),modelVersion:'synthetic-v1'};}},config);
 assert.equal(generated,1);assert.equal(calls.at(-1),'qiyadat_feedback_complete');});
test('lost completion acknowledgement replays same validated output with one provider call',async()=>{let complete=0,generated=0;const service=client(name=>{if(name.endsWith('complete')&&++complete===1)throw new Error('PRIVATE-DB');return name.endsWith('claim')?job:true;});
 await processFeedback(service,{generate:async()=>{generated++;return {output:validFeedback(),modelVersion:'synthetic-v1'};}},config);assert.equal(complete,2);assert.equal(generated,1);});
test('provider errors produce bounded safe retry requests without content',async()=>{let failure:any;const service=client((name,body)=>{if(name.endsWith('_fail'))failure=body;return name.endsWith('claim')?job:true;});
 await processFeedback(service,{generate:async()=>{throw new ApiError('PROVIDER_UNAVAILABLE');}},config);assert.equal(failure.p_code,'PROVIDER_UNAVAILABLE');assert.equal(failure.p_retryable,true);assert.ok(!JSON.stringify(failure).includes(job.responses[0].answer));});
test('revoked consent prevents provider dispatch',async()=>{let generated=0;const service=client(name=>name.endsWith('claim')?job:name.endsWith('authorize')?false:true);
 await processFeedback(service,{generate:async()=>{generated++;throw new Error();}},config);assert.equal(generated,0);});
test('no queued work makes no provider call',async()=>{await processFeedback(client(name=>name.endsWith('claim')?null:true),{generate:async()=>{throw new Error('must not call');}},config);});
test('internal worker rejects public key, user token, forged job/body and logs no content',async()=>{const lines:string[]=[];const worker=createWorker(env,config,{sink:line=>lines.push(line),fetcher:async()=>Response.json(null)});
 for(const token of ['',env.publishableKey,'candidate-token']){const result=await worker(new Request('http://local.invalid/feedback-worker',{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:'{}'}));assert.equal(result.status,401);}
 const forged=await worker(new Request('http://local.invalid/feedback-worker',{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+config.workerSecret},body:JSON.stringify({job_id:'PRIVATE-JOB',answer:'PRIVATE-ANSWER'})}));assert.equal(forged.status,422);assert.ok(!lines.join('').includes('PRIVATE'));assert.ok(!lines.join('').includes(config.workerSecret));
});
