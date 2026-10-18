import type {AuthContext} from './auth.ts';
import {choice,queryParameters} from './validation.ts';
export function progressQuery(url:URL){
 const query=queryParameters(url,['range','compare','practice_mode','response_mode']);
 return {
  p_range:choice(query.range??'30d','range',['7d','30d','90d','all']),
  p_compare:choice(query.compare??'previous_period','compare',['none','previous_period']),
  p_practice_mode:choice(query.practice_mode??'all','practice_mode',['all','training','simulation']),
  p_response_mode:choice(query.response_mode??'all','response_mode',['all','typing','paper']),
 };
}
export async function readProgress(url:URL,context:AuthContext){
 return context.client.rpc('qiyadat_progress',progressQuery(url));
}
