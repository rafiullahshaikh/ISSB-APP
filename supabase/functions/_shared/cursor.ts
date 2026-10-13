import {invalid} from './errors.ts';
import {canonicalJson,sha256} from './idempotency.ts';
import {timestamp,uuid} from './validation.ts';
const encoder=new TextEncoder();
function encode(bytes:Uint8Array):string {return btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');}
function decode(value:string):Uint8Array {if(!/^[a-zA-Z0-9_-]+$/.test(value)) throw new Error('Invalid cursor.');return Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));}
export class Cursors {
 key:Promise<CryptoKey>;
 constructor(serverSecret:string) {
  // Domain separation: do not use or expose a credential directly as a cursor token.
  this.key=(async()=>{const root=await crypto.subtle.importKey('raw',encoder.encode(serverSecret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
   const derived=await crypto.subtle.sign('HMAC',root,encoder.encode('qiyadat-history-cursor-v1'));
   return crypto.subtle.importKey('raw',derived,{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);})();
 }
 async create(position:{at:string;id:string},userId:string,filters:Record<string,string>):Promise<string> {
  const payload=encode(encoder.encode(canonicalJson({v:1,user:userId,filters:await sha256(canonicalJson(filters)),...position})));
  const signature=await crypto.subtle.sign('HMAC',await this.key,encoder.encode(payload));return payload+'.'+encode(new Uint8Array(signature));
 }
 async parse(value:string,userId:string,filters:Record<string,string>):Promise<{at:string;id:string}> {
  try {
   if(value.length>2048) throw new Error('Invalid cursor.');const parts=value.split('.');if(parts.length!==2) throw new Error('Invalid cursor.');
   if(!await crypto.subtle.verify('HMAC',await this.key,decode(parts[1]),encoder.encode(parts[0]))) throw new Error('Invalid cursor.');
   const payload=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(decode(parts[0])));
   if(!payload || Object.keys(payload).sort().join(',')!=='at,filters,id,user,v' || payload.v!==1 || payload.user!==userId || payload.filters!==await sha256(canonicalJson(filters))) throw new Error('Invalid cursor.');
   return {at:timestamp(payload.at,'cursor'),id:uuid(payload.id,'cursor')};
  } catch {invalid('cursor','The cursor is invalid for this history request.');}
 }
}
