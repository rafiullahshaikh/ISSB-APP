import {ApiError} from './errors.ts';
import {userClient,SupabaseClient} from './clients.ts';
import type {Environment} from './env.ts';
export interface AuthContext {id:string;email:string|null;profile:any;account:any;client:SupabaseClient}
export async function authenticate(request:Request,env:Environment,service:SupabaseClient,fetcher:typeof fetch=fetch):Promise<AuthContext> {
 const header=request.headers.get('authorization');if(!header) throw new ApiError('AUTH_REQUIRED');
 const match=/^Bearer ([^\s]+)$/i.exec(header);
 if(!match || match[1]===env.publishableKey || match[1]===env.serviceKey || !request.headers.get('apikey')) throw new ApiError('AUTH_INVALID');
 const client=userClient(env,match[1],fetcher);
 const user=await client.call('/auth/v1/user');
 if(!user || typeof user.id!=='string' || user.is_anonymous===true) throw new ApiError('AUTH_INVALID');
 const profiles=await client.select('profiles',{select:'id,display_name,timezone,created_at',id:'eq.'+user.id,limit:'1'});
 if(profiles.length!==1) throw new ApiError('AUTH_INVALID');
 const account=await service.rpc('qiyadat_account_context',{p_actor:user.id});
 return {id:user.id,email:typeof user.email==='string'?user.email:null,profile:profiles[0],account,client};
}
export async function requireAdmin(context:AuthContext,service:SupabaseClient):Promise<void> {
 if(await service.rpc('qiyadat_admin_check',{p_actor:context.id})!==true) throw new ApiError('ADMIN_REQUIRED');
}
