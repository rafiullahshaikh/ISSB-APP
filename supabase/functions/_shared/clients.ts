import {ApiError,errorStatus} from './errors.ts';
import type {Environment} from './env.ts';
export class SupabaseClient {
 url:string; key:string; token?:string; fetcher:typeof fetch;
 constructor(url:string,key:string,token?:string,fetcher:typeof fetch=fetch) {this.url=url;this.key=key;this.token=token;this.fetcher=fetcher;}
 async call(path:string,method='GET',body?:unknown):Promise<any> {
  const headers=new Headers({apikey:this.key,'Content-Type':'application/json'});
  if(this.token) headers.set('Authorization','Bearer '+this.token);
  let response:Response;
  try {response=await this.fetcher(this.url+path,{method,headers,...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(10000)});}
  catch {throw new ApiError('PROVIDER_UNAVAILABLE');}
  let result:any; try {result=await response.json();} catch {throw new ApiError('PROVIDER_UNAVAILABLE');}
  if(!response.ok) {
   if(path==='/auth/v1/user') throw new ApiError(response.status>=500 ? 'PROVIDER_UNAVAILABLE':'AUTH_INVALID');
   if(result?.code==='P0001' && Object.hasOwn(errorStatus,result.message)) {
    let details:any; try {const parsed=JSON.parse(result.details || '{}');
     if(parsed.fields && typeof parsed.fields==='object' && !Array.isArray(parsed.fields)) {
      const fields:Record<string,string>={}; for(const [key,value] of Object.entries(parsed.fields)) {
       if(/^[a-z_]{1,80}$/.test(key) && typeof value==='string' && value.length<=200) fields[key]=value;
      } if(Object.keys(fields).length) details={fields};
     }
    } catch {/* Database diagnostics are never exposed. */}
    throw new ApiError(result.message,details);
   }
   if(['22P02','22007','22008','23514'].includes(result?.code)) throw new ApiError('VALIDATION_ERROR');
   throw new ApiError(response.status>=500 ? 'PROVIDER_UNAVAILABLE':'INTERNAL_ERROR');
  }
  return result;
 }
 rpc(name:string,body:unknown={}):Promise<any> {return this.call('/rest/v1/rpc/'+name,'POST',body);}
 select(table:string,params:Record<string,string>):Promise<any[]> {
  return this.call('/rest/v1/'+table+'?'+new URLSearchParams(params).toString());
 }
}
export function serviceClient(env:Environment,fetcher:typeof fetch=fetch):SupabaseClient {
 // Never copy caller headers into this client. Modern secret keys use apikey alone;
 // legacy service-role JWTs additionally require their own Authorization header.
 return new SupabaseClient(env.url,env.serviceKey,env.serviceKey.startsWith('eyJ')?env.serviceKey:undefined,fetcher);
}
export function userClient(env:Environment,token:string,fetcher:typeof fetch=fetch):SupabaseClient {
 return new SupabaseClient(env.url,env.publishableKey,token,fetcher);
}
