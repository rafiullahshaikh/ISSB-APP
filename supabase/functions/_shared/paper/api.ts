import {ApiError} from '../errors.ts';
import type {AuthContext} from '../auth.ts';
import type {SupabaseClient} from '../clients.ts';
import type {Environment} from '../env.ts';
import {queryParameters} from '../validation.ts';
import {boundedBytes,MAX_IMAGE,MAX_TOTAL,validateImage} from './images.ts';
import {PaperStorage} from './storage.ts';
const encoder=new TextEncoder();
async function key(secret:string){return crypto.subtle.importKey('raw',encoder.encode('qiyadat-paper-v1:'+secret),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);}
function claim(actor:string,session:string,upload:string,expiry:string){return encoder.encode(JSON.stringify([actor,session,upload,expiry]));}
export async function uploadCapability(secret:string,actor:string,session:string,upload:string,expiry:string){
 const signature=await crypto.subtle.sign('HMAC',await key(secret),claim(actor,session,upload,expiry));
 return Array.from(new Uint8Array(signature),b=>b.toString(16).padStart(2,'0')).join('');
}
export async function verifyCapability(secret:string,actor:string,session:string,upload:string,expiry:string,token:string){
 if(!/^[0-9a-f]{64}$/.test(token))return false;
 const bytes=Uint8Array.from(token.match(/../g)!,p=>parseInt(p,16));
 return crypto.subtle.verify('HMAC',await key(secret),bytes,claim(actor,session,upload,expiry));
}
export async function cleanupPaper(service:SupabaseClient,storage:PaperStorage,sessionId?:string){
 const candidates=await service.rpc('qiyadat_paper_cleanup_candidates',{p_session_id:sessionId??null});let deleted=0,pending=0;
 for(const candidate of candidates){try{await storage.remove(candidate.object_path,candidate.bucket_id);
   if(candidate.id&&await service.rpc('qiyadat_paper_deleted',{p_upload:candidate.id})!==true){pending++;continue;}deleted++;
  }catch{pending++;}}
 return {deleted,pending};
}
export async function paperMutation(operation:string,sessionId:string,body:Record<string,any>,idempotency:string|null,
 context:AuthContext,service:SupabaseClient,env:Environment,fetcher?:typeof fetch){
 const storage=new PaperStorage(env,fetcher);
 if(operation==='paper_prepare'){
  const args={p_actor:context.id,p_session_id:sessionId,p_body:body};let result=await service.rpc('qiyadat_paper_prepare',args);
  if(result.recovering){const cleanup=await cleanupPaper(service,storage,sessionId);if(cleanup.pending)throw new ApiError('PROVIDER_UNAVAILABLE');result=await service.rpc('qiyadat_paper_prepare',args);}
  if(result.recovering)throw new ApiError('PROVIDER_UNAVAILABLE');
  const base=env.publicApiUrl??(['kong','localhost','127.0.0.1'].includes(new URL(env.url).hostname)?'http://127.0.0.1:55321/functions/v1/api/v1':env.url+'/functions/v1/api/v1');
  const uploads=[];
  for(const u of result.uploads){const token=await uploadCapability(env.serviceKey,context.id,sessionId,u.upload_id,u.expires_at);
   uploads.push({upload_id:u.upload_id,page_number:u.page_number,method:'PUT',upload_url:`${base}/wat/sessions/${sessionId}/paper/uploads/${u.upload_id}/content?token=${token}`,
    required_headers:{'content-type':u.content_type},expires_at:u.expires_at});}
  return {status:201,body:{data:{session_id:sessionId,uploads}}};
 }
 if(operation==='paper_ocr'){
  const request={p_actor:context.id,p_session_id:sessionId,p_body:body,p_key:idempotency};
  const contextResult=await service.rpc('qiyadat_paper_ocr_context',request);if(contextResult.replay)return contextResult.replay;
  let total=0;for(const image of contextResult.uploads){total+=Number(image.size_bytes);if(total>MAX_TOTAL)throw new ApiError('UPLOAD_TOO_LARGE');
   try{await validateImage(image,await storage.download(image));}
   catch(error){if(error instanceof ApiError&&['PAPER_UPLOAD_INCOMPLETE','UNSUPPORTED_MEDIA_TYPE','UPLOAD_TOO_LARGE'].includes(error.code)){
     await service.rpc('qiyadat_paper_storage_failure',{p_actor:context.id,p_session_id:sessionId,p_upload:image.id});
    }throw error;}}
  return service.rpc('qiyadat_paper_request_ocr',request);
 }
 if(operation==='paper_confirm'){
  const data=await service.rpc('qiyadat_paper_confirm',{p_actor:context.id,p_session_id:sessionId,p_body:body});
  // Confirmation is committed even if Storage or its acknowledgement is down.
  try{const result=await cleanupPaper(service,storage,sessionId);if(!result.pending)data.images={status:'deleted',delete_pending:false};}catch{}
  return {status:200,body:{data}};
 }
 throw new ApiError('NOT_FOUND');
}
export async function receivePaper(request:Request,sessionId:string,uploadId:string,context:AuthContext,service:SupabaseClient,env:Environment,fetcher?:typeof fetch){
 const query=queryParameters(new URL(request.url),['token']);
 const args={p_actor:context.id,p_session_id:sessionId,p_upload:uploadId};
 const image=await service.rpc('qiyadat_paper_upload_context',args);
 if(!await verifyCapability(env.serviceKey,context.id,sessionId,uploadId,image.upload_expires_at,query.token??''))throw new ApiError('FORBIDDEN');
 if(request.headers.get('content-type')?.toLowerCase()!==image.content_type)throw new ApiError('UNSUPPORTED_MEDIA_TYPE');
 const bytes=await boundedBytes(request.body,MAX_IMAGE);await validateImage(image,bytes);
 const lease=crypto.randomUUID(),storage=new PaperStorage(env,fetcher);
 const current=await service.rpc('qiyadat_paper_upload_context',{...args,p_claim:lease});
 if(current.status==='uploaded')return;
 try{
  await storage.upload(current,bytes);
  if(await service.rpc('qiyadat_paper_upload_complete',{...args,p_claim:lease,p_success:true})!==true)throw new ApiError('SESSION_STATE_CONFLICT');
 }catch(error){
  try{await service.rpc('qiyadat_paper_upload_complete',{...args,p_claim:lease,p_success:false});await cleanupPaper(service,storage,sessionId);}catch{}
  throw error;
 }
}
