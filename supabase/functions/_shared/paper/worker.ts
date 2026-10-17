import {ApiError,normalizeError} from '../errors.ts';
import {serviceClient} from '../clients.ts';
import type {SupabaseClient} from '../clients.ts';
import type {Environment} from '../env.ts';
import {failure,json,parseJson,requestId} from '../http.ts';
import {sha256} from '../idempotency.ts';
import {safeLog} from '../logging.ts';
import {cleanupPaper} from './api.ts';
import {validateImage,MAX_TOTAL} from './images.ts';
import {PaperStorage} from './storage.ts';
import {mapLines,validateLines} from './mapping.ts';
import {VisionFailure,VisionProvider} from './vision.ts';
import type {OcrProvider,VisionConfig} from './vision.ts';
export async function processOcr(service:SupabaseClient,storage:PaperStorage,provider:OcrProvider){
 await service.rpc('qiyadat_ocr_recover');const worker=crypto.randomUUID(),job=await service.rpc('qiyadat_ocr_claim',{p_worker:worker});
 if(!job){if(await service.rpc('qiyadat_ocr_enabled')!==true)throw new ApiError('FEATURE_DISABLED');return {processed:0};}
 const event=async(upload:string,name:string,lines?:unknown)=>{
  const args={p_job:job.id,p_worker:worker,p_upload:upload,p_event:name,...(lines===undefined?{}:{p_lines:lines})};
  try{await service.rpc('qiyadat_ocr_page_event',args);}catch{await service.rpc('qiyadat_ocr_page_event',args);}
 };
 try{let total=0;const lines=[];
  if(!Array.isArray(job.pages)||job.pages.length<1||job.pages.length>4||job.words?.length!==20)throw new ApiError('OCR_FAILED');
  for(const page of job.pages){total+=Number(page.size_bytes);if(total>MAX_TOTAL)throw new ApiError('UPLOAD_TOO_LARGE');
   if(page.lines!==null){lines.push(...validateLines(page.lines));continue;}
   const bytes=await storage.download(page);await validateImage(page,bytes);
   if(!page.uploaded_at||Date.parse(page.uploaded_at)>Date.parse(page.upload_expires_at))throw new ApiError('UPLOAD_EXPIRED');
   await provider.authorize?.();await event(page.id,'dispatch');
   const result=validateLines(await provider.recognize(bytes,job.request_id,()=>event(page.id,'accepted')));
   await event(page.id,'done',result);lines.push(...result);
  }
  const draft=mapLines(lines),args={p_job:job.id,p_worker:worker,p_draft:draft};
  try{await service.rpc('qiyadat_ocr_complete',args);}catch{await service.rpc('qiyadat_ocr_complete',args);}
 }catch(error){const safe=normalizeError(error);
  await service.rpc('qiyadat_ocr_fail',{p_job:job.id,p_worker:worker,p_code:['UPLOAD_TOO_LARGE','PAPER_UPLOAD_INCOMPLETE','VALIDATION_ERROR'].includes(safe.code)?'OCR_FAILED':safe.code,
   p_retryable:error instanceof VisionFailure?error.retryable:['PROVIDER_UNAVAILABLE','INTERNAL_ERROR'].includes(safe.code)});
 }
 return {processed:1};
}
export function createPaperWorker(env:Environment,secret:string,options:{config?:VisionConfig;provider?:OcrProvider;fetcher?:typeof fetch;sink?:(line:string)=>void;cleanup?:boolean}={}){
 const service=serviceClient(env,options.fetcher),storage=new PaperStorage(env,options.fetcher);
 const provider=options.provider??(options.config?new VisionProvider(options.config,options.fetcher):undefined);
 return async(request:Request)=>{
  const id=requestId(request.headers.get('x-request-id')),started=performance.now();let response:Response,code:string|undefined;
  try{const authorization=request.headers.get('authorization');if(!authorization)throw new ApiError('AUTH_REQUIRED');
   if(secret.length<32||await sha256(authorization)!==await sha256('Bearer '+secret))throw new ApiError('AUTH_INVALID');
   if(request.method!=='POST'||new URL(request.url).search)throw new ApiError('INVALID_REQUEST');
   const body=await parseJson(request);if(Object.keys(body).length)throw new ApiError('VALIDATION_ERROR');
   if(!options.cleanup&&!provider)throw new ApiError('FEATURE_DISABLED');
   response=json({data:options.cleanup?await cleanupPaper(service,storage):await processOcr(service,storage,provider!)},200,id,new Headers());
  }catch(error){const safe=normalizeError(error);code=safe.code;response=failure(safe,id,new Headers());}
  try{safeLog({request_id:id,route:options.cleanup?'paper_cleanup':'ocr_worker',method:request.method==='POST'?'POST':'OTHER',status:response.status,duration_ms:performance.now()-started,code},options.sink);}catch{}
  return response;
 };
}
