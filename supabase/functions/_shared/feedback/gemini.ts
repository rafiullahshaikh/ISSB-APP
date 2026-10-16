import {ApiError} from '../errors.ts';
import {geminiRequest} from './prompt.ts';
import {validateOutput} from './output.ts';
import type {FeedbackOutput,ResponseInput} from './schema.ts';
export interface ProviderResult {output:FeedbackOutput;modelVersion:string}
export interface FeedbackProvider {generate(responses:ResponseInput[],model:string,requestId:string):Promise<ProviderResult>}
export interface GeminiConfig {apiKey:string;model:string;promptVersion:string;timeoutMs:number;workerSecret:string;endpoint:string}
export function readGeminiEnvironment(get:(name:string)=>string|undefined):GeminiConfig {
 const apiKey=get('GEMINI_API_KEY')||'',model=get('GEMINI_MODEL')||'',promptVersion=get('GEMINI_PROMPT_VERSION')||'',workerSecret=get('QIYADAT_WORKER_SECRET')||'';
 const timeoutMs=Number(get('GEMINI_REQUEST_TIMEOUT_MS')||'60000');
 if(!apiKey||!/^[a-zA-Z0-9._-]{1,120}$/.test(model)||!/^[a-zA-Z0-9._-]{1,80}$/.test(promptVersion)||workerSecret.length<32||
  !Number.isSafeInteger(timeoutMs)||timeoutMs<100||timeoutMs>120000)throw new ApiError('FEATURE_DISABLED');
 const endpoint=get('QIYADAT_GEMINI_TEST_URL')||'https://generativelanguage.googleapis.com';
 if(endpoint!=='https://generativelanguage.googleapis.com'){
  const supabase=new URL(get('SUPABASE_URL')||'https://invalid'),target=new URL(endpoint);
  if(get('QIYADAT_LOCAL_TESTS')!=='true'||!['kong','127.0.0.1','localhost','host.docker.internal'].includes(supabase.hostname)||
   !['127.0.0.1','localhost','host.docker.internal'].includes(target.hostname)||target.protocol!=='http:'||target.pathname!=='/'||target.username||target.password||target.search||target.hash)throw new ApiError('FEATURE_DISABLED');
 }
 return {apiKey,model,promptVersion,timeoutMs,workerSecret,endpoint};
}
async function boundedJson(response:Response):Promise<any>{
 if(!response.body)throw new ApiError('AI_OUTPUT_INVALID');const reader=response.body.getReader();let size=0;const chunks:Uint8Array[]=[];
 try{while(true){const next=await reader.read();if(next.done)break;size+=next.value.byteLength;if(size>262144){await reader.cancel();throw new ApiError('AI_OUTPUT_INVALID');}chunks.push(next.value);}}
 finally{reader.releaseLock();}
 const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw new ApiError('AI_OUTPUT_INVALID');}
}
export class GeminiProvider implements FeedbackProvider {
 config:GeminiConfig;fetcher:typeof fetch;
 constructor(config:GeminiConfig,fetcher:typeof fetch=fetch){this.config=config;this.fetcher=fetcher;}
 async generate(responses:ResponseInput[],model:string,requestId:string):Promise<ProviderResult>{
  if(!/^[a-zA-Z0-9._-]{1,120}$/.test(model))throw new ApiError('AI_OUTPUT_INVALID');
  let response:Response;
  try{response=await this.fetcher(this.config.endpoint+'/v1beta/models/'+model+':generateContent',{
   method:'POST',headers:{'Content-Type':'application/json','x-goog-api-key':this.config.apiKey,'X-Request-Id':requestId},
   body:JSON.stringify(geminiRequest(responses)),signal:AbortSignal.timeout(this.config.timeoutMs)});}
  catch{throw new ApiError('PROVIDER_UNAVAILABLE');}
  if(!response.ok){await response.body?.cancel();throw new ApiError(response.status===429?'GLOBAL_QUOTA_EXHAUSTED':response.status>=500?'PROVIDER_UNAVAILABLE':'AI_OUTPUT_INVALID');}
  let payload:any;
  try{payload=await boundedJson(response);}catch(error){if(error instanceof ApiError)throw error;throw new ApiError('PROVIDER_UNAVAILABLE');}
  const candidate=payload?.candidates?.[0];
  if(payload?.promptFeedback?.blockReason||candidate?.finishReason!=='STOP'||!Array.isArray(candidate?.content?.parts))throw new ApiError('AI_OUTPUT_INVALID');
  let output:unknown;try{output=JSON.parse(candidate.content.parts.filter((p:any)=>!p.thought&&typeof p.text==='string').map((p:any)=>p.text).join(''));}catch{throw new ApiError('AI_OUTPUT_INVALID');}
  const modelVersion=payload.modelVersion;
  if(typeof modelVersion!=='string'||!/^[a-zA-Z0-9._-]{1,120}$/.test(modelVersion))throw new ApiError('AI_OUTPUT_INVALID');
  return {output:validateOutput(output,responses),modelVersion};
 }
}
