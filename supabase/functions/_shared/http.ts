import {ApiError,errorEnvelope} from './errors.ts';
export function requestId(value:string|null):string {
 if(value && (/^req_[a-zA-Z0-9_-]{16,64}$/.test(value) || /^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$/.test(value))) return value;
 return 'req_'+crypto.randomUUID().replaceAll('-','');
}
export function cors(request:Request,origins:Set<string>):Headers {
 const headers=new Headers({'Vary':'Origin','Access-Control-Expose-Headers':'X-Request-Id, ETag'});
 const origin=request.headers.get('origin');
 if(origin) {if(!origins.has(origin)) throw new ApiError('FORBIDDEN'); headers.set('Access-Control-Allow-Origin',origin);}
 return headers;
}
const allowedHeaders=new Set(['authorization','apikey','content-type','idempotency-key','x-request-id','if-none-match']);
export function preflight(request:Request,headers:Headers,methods:string[]):Response {
 const method=request.headers.get('access-control-request-method');
 if(!method || !methods.includes(method)) throw new ApiError('INVALID_REQUEST');
 for(const header of (request.headers.get('access-control-request-headers') || '').split(',').map(v=>v.trim().toLowerCase()).filter(Boolean)) {
  if(!allowedHeaders.has(header)) throw new ApiError('INVALID_REQUEST');
 }
 headers.set('Access-Control-Allow-Methods',methods.join(', '));
 headers.set('Access-Control-Allow-Headers',[...allowedHeaders].join(', '));
 headers.set('Access-Control-Max-Age','600'); headers.set('Cache-Control','private, no-store');
 return new Response(null,{status:204,headers});
}
export function json(body:unknown,status:number,id:string,headers:Headers,publicCache=false):Response {
 headers.set('Content-Type','application/json; charset=utf-8'); headers.set('X-Request-Id',id);
 headers.set('Cache-Control',publicCache ? 'public, max-age=30' : 'private, no-store');
 return new Response(JSON.stringify(body),{status,headers});
}
export function failure(error:ApiError,id:string,headers:Headers):Response {return json(errorEnvelope(error,id),error.status,id,headers);}
export function etagMatches(value:string|null,current:string):boolean {
 if(!value) return false;
 const normalize=(tag:string)=>tag.trim().replace(/^W\//i,'');
 return value.split(',').some(tag=>tag.trim()==='*' || normalize(tag)===normalize(current));
}
export async function parseJson(request:Request):Promise<Record<string,any>> {
 if(request.headers.get('content-type')?.split(';')[0].trim().toLowerCase()!=='application/json') throw new ApiError('INVALID_REQUEST');
 if(!request.body) throw new ApiError('INVALID_JSON');
 const reader=request.body.getReader(); let bytes=0; const chunks:Uint8Array[]=[];
 try {while(true) {const next=await reader.read(); if(next.done) break; bytes+=next.value.byteLength;
   if(bytes>131072) {await reader.cancel(); throw new ApiError('INVALID_REQUEST');} chunks.push(next.value);}}
 finally {reader.releaseLock();}
 const data=new Uint8Array(bytes); let offset=0; for(const chunk of chunks){data.set(chunk,offset);offset+=chunk.length;}
 let body:any;
 try {body=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(data));} catch {throw new ApiError('INVALID_JSON');}
 if(!body || Array.isArray(body) || typeof body!=='object') throw new ApiError('VALIDATION_ERROR',{fields:{body:'Must be an object.'}});
 return body;
}
