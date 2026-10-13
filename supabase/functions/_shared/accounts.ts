import type {AuthContext} from './auth.ts';
import type {SupabaseClient} from './clients.ts';
export function accountObject(context:AuthContext) {
 return {id:context.id,email:context.email,display_name:context.profile.display_name,timezone:context.profile.timezone,
  ...context.account,created_at:context.profile.created_at};
}
export async function refreshedAccount(context:AuthContext,service:SupabaseClient) {
 const profiles=await context.client.select('profiles',{select:'id,display_name,timezone,created_at',id:'eq.'+context.id,limit:'1'});
 context.profile=profiles[0];context.account=await service.rpc('qiyadat_account_context',{p_actor:context.id});return accountObject(context);
}
