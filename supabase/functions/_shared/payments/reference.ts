import {ApiError,invalid} from '../errors.ts';
import {sha256} from '../idempotency.ts';
const utf8=new TextEncoder();
export const paymentMethods=['easypaisa','jazzcash','bank_transfer'];
export function normalizeReference(value:unknown):string {
 if(typeof value!=='string'||value.length>10000||/[\p{Cc}\p{Cf}\p{Cs}]/u.test(value))invalid('transaction_id','Invalid transaction reference.');
 const normalized=value.normalize('NFC').trim();
 if(!normalized||[...normalized].length>100)invalid('transaction_id','Must contain 1 to 100 Unicode code points.');
 return normalized;
}
export function maskReference(normalized:string):string {
 const chars=[...normalized];return '********'+(chars.length>4?chars.slice(-4).join(''):'*');
}
export async function referenceHash(normalized:string):Promise<string>{return sha256(normalized);}
async function key(value:string|undefined):Promise<CryptoKey>{
 try{
  if(!value||!/^([A-Za-z0-9+/]{43})=$/.test(value))throw new Error();
  const bytes=Uint8Array.from(atob(value),c=>c.charCodeAt(0));
  if(bytes.length!==32||btoa(String.fromCharCode(...bytes))!==value)throw new Error();
  return await crypto.subtle.importKey('raw',bytes,'AES-GCM',false,['encrypt','decrypt']);
 }catch{throw new ApiError('INTERNAL_ERROR');}
}
function aad(method:string,hash:string):Uint8Array {
 if(!paymentMethods.includes(method)||!/^[a-f0-9]{64}$/.test(hash))throw new ApiError('INTERNAL_ERROR');
 return utf8.encode('qiyadat-payment-v1:'+method+':'+hash);
}
export async function encryptReference(normalized:string,method:string,hash:string,secret:string|undefined):Promise<string>{
 try{
  const cryptoKey=await key(secret),iv=crypto.getRandomValues(new Uint8Array(12));
  const encrypted=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad(method,hash),tagLength:128},cryptoKey,utf8.encode(normalized)));
  const envelope=new Uint8Array(1+iv.length+encrypted.length);envelope[0]=1;envelope.set(iv,1);envelope.set(encrypted,13);
  return '\\x'+Array.from(envelope,b=>b.toString(16).padStart(2,'0')).join('');
 }catch{throw new ApiError('INTERNAL_ERROR');}
}
export async function decryptReference(envelope:string,method:string,hash:string,secret:string|undefined):Promise<string>{
 try{
  const cryptoKey=await key(secret);
  if(!/^\\x(?:[a-f0-9]{2}){30,429}$/.test(envelope))throw new Error();
  const bytes=Uint8Array.from(envelope.slice(2).match(/../g)!,h=>parseInt(h,16));if(bytes[0]!==1)throw new Error();
  const plain=await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(1,13),additionalData:aad(method,hash),tagLength:128},cryptoKey,bytes.slice(13));
  const value=new TextDecoder('utf-8',{fatal:true}).decode(plain);
  if(normalizeReference(value)!==value||await referenceHash(value)!==hash)throw new Error();return value;
 }catch{throw new ApiError('INTERNAL_ERROR');}
}
