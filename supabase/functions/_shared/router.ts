import {ApiError,normalizeError} from './errors.ts';
import {serviceClient} from './clients.ts';
import {authenticate} from './auth.ts';
import {accountObject,refreshedAccount} from './accounts.ts';
import {sessionDetail,history} from './sessions.ts';
import {Cursors} from './cursor.ts';
import {cors,etagMatches,failure,json,parseJson,preflight,requestId} from './http.ts';
import {idempotencyKey,sha256,canonicalJson} from './idempotency.ts';
import {queryParameters,validateBody,uuid,integer} from './validation.ts';
import {safeLog} from './logging.ts';
import type {Environment} from './env.ts';
import {getJob,getReport,requestReport} from './feedback/reports.ts';
import {paperMutation,receivePaper} from './paper/api.ts';
import {readProgress} from './progress.ts';
import {submitPayment,paymentHistory,decidePayment} from './payments/api.ts';
interface Route {name:string;methods:string[];public?:boolean;session?:string;position?:string;job?:string;upload?:string;payment?:string}
function route(path:string):Route {
 if(path==='/health') return {name:'health',methods:['GET'],public:true};
 if(path==='/config/wat') return {name:'config',methods:['GET'],public:true};
 if(path==='/me') return {name:'account',methods:['GET','PATCH']};
 if(path==='/progress') return {name:'progress',methods:['GET']};
 if(path==='/payment-offers') return {name:'payment_offers',methods:['GET'],public:true};
 if(path==='/payments') return {name:'payments',methods:['GET','POST']};
 if(path==='/admin/payments') return {name:'admin_payments',methods:['GET']};
 const payment=/^\/admin\/payments\/([^/]+)\/(approve|reject)$/.exec(path);
 if(payment)return {name:'payment_'+payment[2],methods:['POST'],payment:payment[1]};
 if(path==='/wat/sessions') return {name:'sessions',methods:['GET','POST']};
 if(path==='/wat/sessions/import') return {name:'import',methods:['POST']};
 let match=/^\/wat\/sessions\/([^/]+)\/paper\/uploads\/([^/]+)\/content$/.exec(path);
 if(match)return {name:'paper_content',methods:['PUT'],session:match[1],upload:match[2]};
 match=/^\/wat\/sessions\/([^/]+)\/paper\/(uploads|ocr|confirm)$/.exec(path);
 if(match)return {name:match[2]==='uploads'?'paper_prepare':'paper_'+match[2],methods:match[2]==='ocr'?['GET','POST']:match[2]==='uploads'?['POST']:['PUT'],session:match[1]};
 match=/^\/jobs\/([^/]+)$/.exec(path);
 if(match) return {name:'job',methods:['GET'],job:match[1]};
 match=/^\/wat\/sessions\/([^/]+)\/report$/.exec(path);
 if(match) return {name:'report',methods:['GET','POST'],session:match[1]};
 match=/^\/wat\/sessions\/([^/]+)\/answers\/([^/]+)$/.exec(path);
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
     } else if(name==='payment_offers') {queryParameters(url,[]);data=await service.rpc('qiyadat_payment_offers');
     } else {
      const query=queryParameters(url,['kind']);if(!['diagnostic','practice'].includes(query.kind)) throw new ApiError('INVALID_REQUEST');
      data=await service.rpc('qiyadat_public_config',{p_kind:query.kind});
     }
     const body={data};headers.set('ETag','"'+await sha256(canonicalJson(body))+'"');
     response=json(body,200,id,headers,true);
     if(etagMatches(request.headers.get('if-none-match'),headers.get('etag')!)) response=new Response(null,{status:304,headers:response.headers});
    } else {
     const context=await authenticate(request,env,service,options.fetcher);
     let session:string|undefined;
     if(found.session) {try {session=uuid(found.session);} catch {throw new ApiError('NOT_FOUND');}}
     if(name==='paper_content'){
      let upload:string;try{upload=uuid(found.upload);}catch{throw new ApiError('NOT_FOUND');}
      await receivePaper(request,session!,upload,context,service,env,options.fetcher);
      headers.set('Cache-Control','private, no-store');headers.set('X-Request-Id',id);response=new Response(null,{status:204,headers});
     }else if(request.method==='GET') {
      if(name==='sessions') response=json(await history(url,context,cursors),200,id,headers);
      else if(name==='payments'||name==='admin_payments')response=json(await paymentHistory(url,context,service,cursors,env,name==='admin_payments'),200,id,headers);
      else if(name==='progress') response=json({data:await readProgress(url,context)},200,id,headers);
      else {queryParameters(url,[]);let data:any;
       if(name==='account')data=accountObject(context);
       else if(name==='report')data=await getReport(session!,context);
       else if(name==='paper_ocr')data=await context.client.rpc('qiyadat_paper_draft',{p_session_id:session});
       else if(name==='job'){let job:string;try{job=uuid(found.job);}catch{throw new ApiError('NOT_FOUND');}data=await getJob(job,context,service);}
       else data=await sessionDetail(session!,context,service);
       response=json({data},200,id,headers);}
     } else if(name==='payments'||name==='payment_approve'||name==='payment_reject'){
      queryParameters(url,[]);
      const key=name==='payments'?idempotencyKey(request):null;
      const body=await parseJson(request,true);
      if(name==='payments'){const result=await submitPayment(body,key!,context,service,env);response=json(result.body,result.status,id,headers);}
      else {const payment=uuid(found.payment,'payment_id');response=json({data:await decidePayment(name.slice(8),payment,body,id,context,service)},200,id,headers);}
     } else {
      queryParameters(url,[]);
      const operation=name==='sessions'?'start':name==='account'?'profile':name;
      const key=['start','finish','import','report','paper_ocr'].includes(operation)?idempotencyKey(request):null;
      let position:number|null=null;
      if(found.position!==undefined) {
       if(!/^\d{1,2}$/.test(found.position)) throw new ApiError('VALIDATION_ERROR',{fields:{position:'Must be 1 to 20.'}});
       position=integer(Number(found.position),'position',1,20);
      }
      const parsed=await parseJson(request);
      const body=operation==='report'||operation.startsWith('paper_')?parsed:validateBody(operation,parsed);
      const result=operation.startsWith('paper_')?await paperMutation(operation,session!,body,key,context,service,env,options.fetcher):operation==='report'?await requestReport(session!,body,key!,context,service):
       await service.rpc('qiyadat_mutate',{p_actor:context.id,p_operation:operation,p_body:body,p_key:key,p_session_id:session??null,p_position:position});
      response=json(operation==='profile'?{data:await refreshedAccount(context,service)}:result.body,result.status,id,headers);
     }
    }
   }
  } catch (error) {let safe=normalizeError(error);
   if(name==='progress'&&request.method==='GET'&&!['AUTH_REQUIRED','AUTH_INVALID','VALIDATION_ERROR','INTERNAL_ERROR'].includes(safe.code))safe=new ApiError('INTERNAL_ERROR');
   if((name.includes('payment'))&&safe.code==='PROVIDER_UNAVAILABLE')safe=new ApiError('INTERNAL_ERROR');
   code=safe.code;response=failure(safe,id,headers);}
  try {safeLog({request_id:id,route:name,method:['GET','POST','PUT','PATCH','DELETE','OPTIONS','HEAD'].includes(request.method)?request.method:'OTHER',
   status:response.status,duration_ms:performance.now()-started,code},options.sink);} catch {/* Logging must not change an API result. */}
  return response;
 };
}
