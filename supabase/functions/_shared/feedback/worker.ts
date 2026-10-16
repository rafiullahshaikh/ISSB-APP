import {ApiError,normalizeError} from '../errors.ts';
import {serviceClient} from '../clients.ts';
import {failure,json,parseJson,requestId} from '../http.ts';
import {sha256} from '../idempotency.ts';
import {safeLog} from '../logging.ts';
import type {Environment} from '../env.ts';
import type {SupabaseClient} from '../clients.ts';
import {GeminiProvider} from './gemini.ts';
import type {FeedbackProvider,GeminiConfig} from './gemini.ts';
import {classifyFailure} from './retry.ts';
import {validateOutput} from './output.ts';
export async function processFeedback(service:SupabaseClient,provider:FeedbackProvider,config:GeminiConfig){
 await service.rpc('qiyadat_feedback_recover');
 const worker=crypto.randomUUID(),job=await service.rpc('qiyadat_feedback_claim',{p_worker:worker,p_model:config.model,p_prompt:config.promptVersion});
 if(!job)return {processed:0};
 try{
  if(await service.rpc('qiyadat_feedback_authorize',{p_job:job.id,p_worker:worker})!==true)throw new ApiError('AI_CONSENT_REQUIRED');
  const result=await provider.generate(job.responses,job.model,job.request_id);
  const output=validateOutput(result.output,job.responses);
  // Replaying the same completion covers a lost HTTP acknowledgement, without
  // sending a second provider request or persisting raw provider output.
  const complete=()=>service.rpc('qiyadat_feedback_complete',{p_job:job.id,p_worker:worker,p_output:output,p_model_version:result.modelVersion});
  try{await complete();}catch{await complete();}
 }catch(error){const safe=classifyFailure(error);
  await service.rpc('qiyadat_feedback_fail',{p_job:job.id,p_worker:worker,p_code:safe.code,p_retryable:safe.retryable});
 }
 return {processed:1};
}
export function createWorker(env:Environment,config:GeminiConfig,options:{provider?:FeedbackProvider;fetcher?:typeof fetch;sink?:(line:string)=>void}={}){
 const service=serviceClient(env,options.fetcher),provider=options.provider??new GeminiProvider(config,options.fetcher);
 return async(request:Request)=>{
  const id=requestId(request.headers.get('x-request-id')),started=performance.now(),headers=new Headers();let response:Response,code:string|undefined;
  try{
   const authorization=request.headers.get('authorization');
   if(!authorization)throw new ApiError('AUTH_REQUIRED');
   if(await sha256(authorization)!==await sha256('Bearer '+config.workerSecret))throw new ApiError('AUTH_INVALID');
   if(request.method!=='POST'||new URL(request.url).search)throw new ApiError('INVALID_REQUEST');
   const body=await parseJson(request);if(Object.keys(body).length)throw new ApiError('VALIDATION_ERROR');
   response=json({data:await processFeedback(service,provider,config)},200,id,headers);
  }catch(error){const safe=normalizeError(error);code=safe.code;response=failure(safe,id,headers);}
  try{safeLog({request_id:id,route:'feedback_worker',method:request.method==='POST'?'POST':'OTHER',status:response.status,duration_ms:performance.now()-started,code},options.sink);}catch{}
  return response;
 };
}
