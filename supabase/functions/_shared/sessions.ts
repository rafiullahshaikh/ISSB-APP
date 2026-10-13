import {ApiError} from './errors.ts';
import type {AuthContext} from './auth.ts';
import type {SupabaseClient} from './clients.ts';
import type {Cursors} from './cursor.ts';
import {historyQuery} from './validation.ts';
export async function sessionDetail(id:string,context:AuthContext,service:SupabaseClient) {
 const sessions=await context.client.select('wat_sessions',{select:'id,schema_version,kind,status,practice_mode,response_mode,source,timing_trust,started_at,finished_at,ended_early,wat_set_id,set_version,ocr_revision',id:'eq.'+id,limit:'1'});
 if(sessions.length!==1) throw new ApiError('NOT_FOUND');const s=sessions[0];
 const [responses,sets,reports]=await Promise.all([
  context.client.select('wat_responses',{select:'position,word,answer,source,status,time_used_ms',session_id:'eq.'+id,order:'position.asc',limit:'20'}),
  service.select('wat_sets',{select:'code,version',id:'eq.'+s.wat_set_id,version:'eq.'+s.set_version,limit:'1'}),
  context.client.select('feedback_reports',{select:'id,status',session_id:'eq.'+id,order:'generated_at.desc,id.desc',limit:'1'}),
 ]);
 return {id:s.id,schema_version:s.schema_version,kind:s.kind,status:s.status,practice_mode:s.practice_mode,response_mode:s.response_mode,
  source:s.source,timing_trust:s.timing_trust,started_at:s.started_at,finished_at:s.finished_at,ended_early:s.ended_early,
  set:{code:sets[0].code,version:sets[0].version},responses,
  ocr:s.ocr_revision>0 ? {status:s.status,ocr_revision:s.ocr_revision}:null,report:reports[0]??null};
}
export async function history(url:URL,context:AuthContext,cursors:Cursors) {
 const {limit,filters,cursor}=historyQuery(url);
 const position=cursor===undefined?null:await cursors.parse(cursor,context.id,filters);
 const result=await context.client.rpc('qiyadat_history',{p_filters:filters,p_cursor:position,p_limit:limit});
 return {data:result.items,meta:{has_more:result.has_more,next_cursor:result.has_more ? await cursors.create(result.next,context.id,filters):null}};
}
