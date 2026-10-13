import {ApiError,invalid} from './errors.ts';
export const statuses=['in_progress','finished','awaiting_upload','ocr_processing','awaiting_confirmation','feedback_processing','ready','failed'];
export function fields(value:Record<string,any>,allowed:string[],required:string[]=[]) {
 if(Object.keys(value).some(k=>!allowed.includes(k))) invalid('body','Unknown properties are not allowed.');
 for(const name of required) if(!Object.hasOwn(value,name) || value[name]===null) invalid(name,'Required.');
}
export function text(value:any,name:string,min:number,max:number):string {
 if(typeof value!=='string' || [...value].length<min || [...value].length>max || /[\uD800-\uDFFF\u0000]/u.test(value)) invalid(name,'Invalid text length or type.');
 return value;
}
export function integer(value:any,name:string,min:number,max:number):number {
 if(!Number.isSafeInteger(value) || value<min || value>max) invalid(name,'Integer out of range.'); return value;
}
export function choice(value:any,name:string,options:string[]):string {
 if(typeof value!=='string' || !options.includes(value)) invalid(name,'Unsupported value.'); return value;
}
export function uuid(value:any,name='id'):string {
 if(typeof value!=='string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)) invalid(name,'Must be a UUID.');
 return value.toLowerCase();
}
export function timestamp(value:any,name:string):string {
 if(typeof value!=='string') invalid(name,'Must be an RFC 3339 timestamp.');
 const parts=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/.exec(value);
 if(!parts || !Number.isFinite(Date.parse(value))) invalid(name,'Must be an RFC 3339 timestamp.');
 const [year,month,day,hour,minute,second]=parts.slice(1,7).map(Number);
 const leap=year%4===0 && (year%100!==0 || year%400===0);
 const days=[31,leap?29:28,31,30,31,30,31,31,30,31,30,31];
 if(year<1 || month<1 || month>12 || day<1 || day>days[month-1] || hour>23 || minute>59 || second>59) invalid(name,'Invalid timestamp.');
 if(parts[7]!=='Z') {const [h,m]=parts[7].slice(1).split(':').map(Number); if(h>23 || m>59) invalid(name,'Invalid timezone offset.');}
 return value;
}
function boolean(value:any,name:string):boolean {if(typeof value!=='boolean') invalid(name,'Must be a boolean.');return value;}
export function normalizeAnswer(value:any,name='answer'):string {
 const normalized=text(value,name,0,131072).replace(/\r\n?/g,'\n').normalize('NFC');
 if([...normalized].length>280) invalid(name,'Maximum 280 Unicode code points after normalization.'); return normalized;
}
function modes(body:Record<string,any>) {
 choice(body.kind,'kind',['diagnostic','practice']);choice(body.practice_mode,'practice_mode',['training','simulation']);
 choice(body.response_mode,'response_mode',['typing','paper']);
}
export function validateBody(operation:string,body:Record<string,any>):Record<string,any> {
 const result={...body};
 if(operation==='start') {
  const names=['client_session_id','set_id','set_version','kind','practice_mode','response_mode','session_size'];fields(body,names,names);
  text(body.client_session_id,'client_session_id',1,128);result.set_id=uuid(body.set_id,'set_id');
  integer(body.set_version,'set_version',1,2147483647);integer(body.session_size,'session_size',20,20);modes(body);
 } else if(operation==='answer') {
  fields(body,['answer','client_elapsed_ms','client_saved_at','advance_reason'],['answer']);result.answer=normalizeAnswer(body.answer);
  if(Object.hasOwn(body,'client_elapsed_ms')) integer(body.client_elapsed_ms,'client_elapsed_ms',0,2147483647);
  if(Object.hasOwn(body,'client_saved_at')) timestamp(body.client_saved_at,'client_saved_at');
  if(Object.hasOwn(body,'advance_reason')) choice(body.advance_reason,'advance_reason',['timer','next','session_end','autosave']);
 } else if(operation==='finish') {
  fields(body,['reason','client_completed_at'],['reason']);choice(body.reason,'reason',['natural','manual']);
  if(Object.hasOwn(body,'client_completed_at')) timestamp(body.client_completed_at,'client_completed_at');
 } else if(operation==='profile') {
  fields(body,['display_name','timezone','accept_ai_processing_terms_version']);if(!Object.keys(body).length) invalid('body','At least one field is required.');
  if(Object.hasOwn(body,'display_name')) result.display_name=text(text(body.display_name,'display_name',1,10000).trim(),'display_name',1,80);
  if(Object.hasOwn(body,'timezone')) text(body.timezone,'timezone',1,100); // PostgreSQL validates the actual IANA registry.
  if(Object.hasOwn(body,'accept_ai_processing_terms_version')) text(body.accept_ai_processing_terms_version,'accept_ai_processing_terms_version',1,80);
 } else if(operation==='import') {
  const names=['schema_version','client_session_id','source','set_code','set_version','kind','practice_mode','response_mode','started_at','completed_at','ended_early','responses'];fields(body,names,names);
  integer(body.schema_version,'schema_version',1,1);text(body.client_session_id,'client_session_id',1,128);
  choice(body.source,'source',['guest_local','legacy_local_storage']);text(body.set_code,'set_code',1,80);
  integer(body.set_version,'set_version',1,2147483647);modes(body);
  timestamp(body.started_at,'started_at');timestamp(body.completed_at,'completed_at');boolean(body.ended_early,'ended_early');
  if(Date.parse(body.completed_at)<Date.parse(body.started_at)) invalid('completed_at','Cannot precede started_at.');
  if(!Array.isArray(body.responses) || body.responses.length!==20) invalid('responses','Exactly 20 positions are required.');
  const seen=new Set<number>();result.responses=body.responses.map((entry:any)=>{
   if(!entry || Array.isArray(entry) || typeof entry!=='object') invalid('responses','Each response must be an object.');
   fields(entry,['position','word','answer','completed','time_used_ms'],['position','word','answer','completed','time_used_ms']);
   integer(entry.position,'responses',1,20);if(seen.has(entry.position)) invalid('responses','Positions must be unique.');seen.add(entry.position);
   text(entry.word,'responses',1,80);const answer=normalizeAnswer(entry.answer,'responses');boolean(entry.completed,'responses');
   integer(entry.time_used_ms,'responses',0,2147483647);if(!entry.completed && answer!=='') invalid('responses','Unattempted positions cannot contain an answer.');
   return {...entry,answer};
  });
 } else throw new ApiError('INVALID_REQUEST');
 return result;
}
export function queryParameters(url:URL,allowed:string[]):Record<string,string> {
 const result:Record<string,string>={};for(const [key,value] of url.searchParams) {
  if(!allowed.includes(key) || Object.hasOwn(result,key)) invalid('query','Unknown or duplicate query parameter.');result[key]=value;
 }return result;
}
export function historyQuery(url:URL) {
 const query=queryParameters(url,['limit','cursor','kind','practice_mode','response_mode','status','from','to']);
 let limit=20;if(query.limit!==undefined) {if(!/^\d{1,3}$/.test(query.limit)) invalid('limit','Must be 1 to 100.');limit=integer(Number(query.limit),'limit',1,100);}
 const filters:Record<string,string>={};
 for(const [name,options] of Object.entries({kind:['diagnostic','practice'],practice_mode:['training','simulation'],response_mode:['typing','paper'],status:statuses})) {
  if(query[name]!==undefined) filters[name]=choice(query[name],name,options);
 }
 for(const name of ['from','to']) if(query[name]!==undefined) filters[name]=timestamp(query[name],name);
 if(filters.from && filters.to && Date.parse(filters.from)>Date.parse(filters.to)) invalid('to','Cannot precede from.');
 return {limit,filters,cursor:query.cursor};
}
