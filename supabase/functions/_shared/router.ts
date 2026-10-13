import {ApiError,normalizeError} from './errors.ts';
import {serviceClient} from './clients.ts';
import {authenticate} from './auth.ts';
import {accountObject,refreshedAccount} from './accounts.ts';
import {sessionDetail,history} from './sessions.ts';
import {Cursors} from './cursor.ts';
import {cors,failure,json,parseJson,preflight,requestId} from './http.ts';
import {idempotencyKey,sha256,canonicalJson} from './idempotency.ts';
import {queryParameters,validateBody,uuid,integer} from './validation.ts';
import {safeLog} from './logging.ts';
import type {Environment} from './env.ts';
interface Route {name:string;methods:string[];public?:boolean;session?:string;position?:string}
function route(path:string):Route {
 if(path==='/health') return {name:'health',methods:['GET'],public:true};
 if(path==='/config/wat') return {name:'config',methods:['GET'],public:true};
 if(path==='/me') return {name:'account',methods:['GET','PATCH']};
 if(path==='/wat/sessions') return {name:'sessions',methods:['GET','POST']};
 if(path==='/wat/sessions/import') return {name:'import',methods:['POST']};
 let match=/^\/wat\/sessions\/([^/]+)\/answers\/([^/]+)$/.exec(path);
 if(match) return {name:'answer',methods:['PUT'],session:match[1],position:match[2]};
 match=/^\/wat\/sessions\/([^/]+)\/finish$/.exec(path);
 if(match) return {name:'finish',methods:['POST'],session:match[1]};
 match=/^\/wat\/sessions\/([^/]+)$/.exec(path);
 if(match) return {name:'detail',methods:['GET'],session:match[1]};
 throw new ApiError('NOT_FOUND');
}
export function createApp(env:Environment,options:{fetcher?:typeof fetch;sink?:(line:string)=>void}={}) {
 const service=serviceClient(env,options.fetcher);const cursors=new Cursors(env.serviceKey);
 return async (request:Request):Promise<Response>=>{
  const started=performance.now(),id=requestId(request.headers.get('x-request-id'));
  let headers=new Headers({'Vary':'Origin'}),name='unmatched',response:Response,code:string|undefined;
  try {
   headers=cors(request,env.origins);headers.set('X-Request-Id',id);
   const url=new URL(request.url);let path:string;
   if(url.pathname.startsWith('/functions/v1/api/v1/')) path=url.pathname.slice('/functions/v1/api/v1'.length);
   else if(url.pathname.startsWith('/api/v1/')) path=url.pathname.slice('/api/v1'.length);
   else throw new ApiError('NOT_FOUND');
   const found=route(path);name=found.name;
   if(request.method==='OPTIONS') response=preflight(request,headers,found.methods);
   else {
    if(!found.methods.includes(request.method)) throw new ApiError('INVALID_REQUEST');
    if(found.public) {
     let data:any;
     if(name==='health') {
      queryParameters(url,[]);try {if(await service.rpc('qiyadat_health')!==true) throw new Error();} catch {throw new ApiError('PROVIDER_UNAVAILABLE');}
      data={status:'ok',api_version:'v1',release:env.release,database:'up',time:new Date().toISOString()};
     } else {
      const query=queryParameters(url,['kind']);if(!['diagnostic','practice'].includes(query.kind)) throw new ApiError('INVALID_REQUEST');
      data=await service.rpc('qiyadat_public_config',{p_kind:query.kind});
     }
     const body={data};headers.set('ETag','"'+await sha256(canonicalJson(body))+'"');
     response=json(body,200,id,headers,true);
     if(request.headers.get('if-none-match')===headers.get('etag')) response=new Response(null,{status:304,headers:response.headers});
    } else {
     const context=await authenticate(request,env,service,options.fetcher);
     let session:string|undefined;
     if(found.session) {try {session=uuid(found.session);} catch {throw new ApiError('NOT_FOUND');}}
     if(request.method==='GET') {
      if(name==='sessions') response=json(await history(url,context,cursors),200,id,headers);
      else {queryParameters(url,[]);response=json({data:name==='account'?accountObject(context):await sessionDetail(session!,context,service)},200,id,headers);}
     } else {
      queryParameters(url,[]);
      const operation=name==='sessions'?'start':name==='account'?'profile':name;
      const key=['start','finish','import'].includes(operation)?idempotencyKey(request):null;
      let position:number|null=null;
      if(found.position!==undefined) {
       if(!/^\d{1,2}$/.test(found.position)) throw new ApiError('VALIDATION_ERROR',{fields:{position:'Must be 1 to 20.'}});
       position=integer(Number(found.position),'position',1,20);
      }
      const body=validateBody(operation,await parseJson(request));
      const result=await service.rpc('qiyadat_mutate',{p_actor:context.id,p_operation:operation,p_body:body,p_key:key,p_session_id:session??null,p_position:position});
      response=json(operation==='profile'?{data:await refreshedAccount(context,service)}:result.body,result.status,id,headers);
     }
    }
   }
  } catch (error) {const safe=normalizeError(error);code=safe.code;response=failure(safe,id,headers);}
  try {safeLog({request_id:id,route:name,method:['GET','POST','PUT','PATCH','DELETE','OPTIONS','HEAD'].includes(request.method)?request.method:'OTHER',
   status:response.status,duration_ms:performance.now()-started,code},options.sink);} catch {/* Logging must not change an API result. */}
  return response;
 };
}
