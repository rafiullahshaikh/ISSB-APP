import {ApiError,invalid} from '../errors.ts';
import {choice,fields,integer,queryParameters,text,timestamp} from '../validation.ts';
import {requireAdmin} from '../auth.ts';
import type {AuthContext} from '../auth.ts';
import type {SupabaseClient} from '../clients.ts';
import type {Environment} from '../env.ts';
import type {Cursors} from '../cursor.ts';
import {sha256} from '../idempotency.ts';
import {normalizeReference,maskReference,referenceHash,paymentMethods,encryptReference,decryptReference} from './reference.ts';
export const rejectionCodes=['TRANSACTION_NOT_FOUND','AMOUNT_MISMATCH','DUPLICATE_TRANSACTION','WRONG_RECIPIENT','OTHER'];
export function paymentBody(body:Record<string,any>){
 fields(body,['offer_code','payment_method','transaction_id'],['offer_code','payment_method','transaction_id']);
 return {offer_code:text(body.offer_code,'offer_code',1,80),payment_method:choice(body.payment_method,'payment_method',paymentMethods),transaction_id:normalizeReference(body.transaction_id)};
}
export function safePaymentText(value:unknown,name:string):string {
 const normalized=text(value,name,1,10000).normalize('NFC').trim();text(normalized,name,1,500);
 if(/[\p{Cc}\p{Cf}\p{Cs}<>]/u.test(normalized)||/https?:|www\.|\S+@\S+|\b(?:password|secret|api[_ -]?key|bearer|token|iban|account\s*(?:number|no))\b|\b[A-Za-z0-9_+\/-]{32,}\b|\b\d{10,}\b|\b(?:sender|recipient|customer|admin|user)\s*:/i.test(normalized))invalid(name,'Use a brief plain-text verification summary without private data.');
 return normalized;
}
export function decisionBody(operation:string,body:Record<string,any>){
 if(operation==='approve'){fields(body,['verification_note'],['verification_note']);return {verification_note:safePaymentText(body.verification_note,'verification_note')};}
 fields(body,['reason_code','message'],['reason_code','message']);return {reason_code:choice(body.reason_code,'reason_code',rejectionCodes),message:safePaymentText(body.message,'message')};
}
export function paymentQuery(url:URL,admin=false){
 const query=queryParameters(url,admin?['status','payment_method','submitted_from','submitted_to','transaction_id','limit','cursor']:['limit','cursor']);
 let limit=20;if(query.limit!==undefined){if(!/^\d{1,3}$/.test(query.limit))invalid('limit','Must be 1 to 100.');limit=integer(Number(query.limit),'limit',1,100);}
 const filters:Record<string,string>={route:admin?'admin_payments':'payments'};
 if(query.status!==undefined)filters.status=choice(query.status,'status',['pending','approved','rejected']);
 if(query.payment_method!==undefined)filters.payment_method=choice(query.payment_method,'payment_method',paymentMethods);
 for(const name of ['submitted_from','submitted_to'])if(query[name]!==undefined)filters[name]=timestamp(query[name],name);
 if(filters.submitted_from&&filters.submitted_to&&Date.parse(filters.submitted_from)>Date.parse(filters.submitted_to))invalid('submitted_to','Cannot precede submitted_from.');
 return {limit,cursor:query.cursor,filters,reference:query.transaction_id===undefined?undefined:normalizeReference(query.transaction_id)};
}
export async function submitPayment(body:Record<string,any>,key:string,context:AuthContext,service:SupabaseClient,env:Environment){
 const value=paymentBody(body),hash=await referenceHash(value.transaction_id);
 const ciphertext=await encryptReference(value.transaction_id,value.payment_method,hash,env.paymentEncryptionKey);
 const result=await service.rpc('qiyadat_payment_submit',{p_actor:context.id,p_key:key,p_body:{offer_code:value.offer_code,payment_method:value.payment_method,transaction_hash:hash},
  p_ciphertext:ciphertext,p_hash:hash,p_masked:maskReference(value.transaction_id)});
 if(result.error_code)throw new ApiError(result.error_code);return result;
}
export async function paymentHistory(url:URL,context:AuthContext,service:SupabaseClient,cursors:Cursors,env:Environment,admin=false){
 if(admin)await requireAdmin(context,service);
 const {limit,cursor,filters,reference}=paymentQuery(url,admin);
 if(reference!==undefined)filters.transaction_hash=await referenceHash(reference);
 const position=cursor===undefined?null:await cursors.parse(cursor,context.id,filters);
 const {route:_,...rpcFilters}=filters;
 const rows=admin?await service.rpc('qiyadat_admin_payments',{p_actor:context.id,p_filters:rpcFilters,p_cursor:position,p_limit:limit}):
  await context.client.rpc('qiyadat_payment_history',{p_cursor:position,p_limit:limit});
 const more=rows.length>limit,page=rows.slice(0,limit),last=page.at(-1);
 const next=more?await cursors.create({at:last.submitted_at,id:last.id},context.id,filters):null;
 const data=admin?await Promise.all(page.map(async(row:any)=>({id:row.id,user:row.user,offer:row.offer,payment_method:row.payment_method,
  transaction_id:await decryptReference(row.ciphertext,row.payment_method,row.hash,env.paymentEncryptionKey),status:row.status,submitted_at:row.submitted_at}))):page;
 return {data,meta:{next_cursor:next,has_more:more}};
}
export async function auditRequestId(id:string):Promise<string>{
 if(/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id))return id;
 const h=await sha256('qiyadat-payment-audit-request-v1:'+id);return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20,32)}`;
}
export async function decidePayment(operation:string,id:string,body:Record<string,any>,requestId:string,context:AuthContext,service:SupabaseClient){
 await requireAdmin(context,service);const validated=decisionBody(operation,body);
 return service.rpc('qiyadat_payment_decide',{p_actor:context.id,p_payment_id:id,p_operation:operation,p_body:validated,p_request_id:await auditRequestId(requestId)});
}
