import {ApiError} from '../errors.ts';
import {fields,choice} from '../validation.ts';
import type {AuthContext} from '../auth.ts';
import type {SupabaseClient} from '../clients.ts';
import {DISCLAIMER,dimensions,RUBRIC_VERSION} from './schema.ts';
import {scoreLabel} from './scoring.ts';
export function validateReportRequest(body:Record<string,any>){fields(body,['rubric_version'],['rubric_version']);choice(body.rubric_version,'rubric_version',[RUBRIC_VERSION]);return body;}
export async function requestReport(sessionId:string,body:Record<string,any>,key:string,context:AuthContext,service:SupabaseClient){
 // SQL checks an existing key's canonical hash before validating the supported
 // rubric, so changed input cannot disguise an idempotency conflict.
 return service.rpc('qiyadat_request_report',{p_actor:context.id,p_session_id:sessionId,p_body:body,p_key:key});
}
export async function getReport(sessionId:string,context:AuthContext){
 const report=await context.client.rpc('qiyadat_report_read',{p_session_id:sessionId});
 return {id:report.id,session_id:report.session_id,status:'ready',rubric_version:report.rubric_version,prompt_version:report.prompt_version,
  model:{provider:report.model_provider,name:report.model_name},generated_at:report.generated_at,
  score:{overall:report.overall_score,maximum:10,label:scoreLabel(report.overall_score)},
  dimensions:Object.fromEntries(dimensions.map(d=>[d,{score:report[d+'_score'],maximum:10,label:scoreLabel(report[d+'_score'],d)}])),
  sentences:report.sentences.map((item:any)=>({position:item.position,word:item.word,response:item.response,response_source:item.response_source,
   status:item.status,score:item.score,ratings:item.status==='not_scored'?null:Object.fromEntries(dimensions.map(d=>[d,{
    rating:item[d+'_rating'],maximum:5,label:item.rating_notes[d].label,note:item.rating_notes[d].note}])),
   strength:item.strength,feedback:item.feedback,safety_flags:item.safety_flags})),summary:report.summary,disclaimer:DISCLAIMER};
}
export async function getJob(id:string,context:AuthContext,service:SupabaseClient){
 const job=await service.rpc('qiyadat_job_read',{p_actor:context.id,p_job:id});
 const {error_code,...result}=job;
 return {...result,error:error_code?{code:new ApiError(error_code).code,message:new ApiError(error_code).message}:null};
}
