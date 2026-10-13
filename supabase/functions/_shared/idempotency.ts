import {invalid} from './errors.ts';
export function idempotencyKey(request:Request):string {
 const key=request.headers.get('idempotency-key');
 if(!key || !/^[\x20-\x7e]{16,128}$/.test(key)) invalid('idempotency_key','Must be 16 to 128 printable ASCII characters.');
 return key;
}
export function canonicalJson(value:any):string {
 if(value===null || typeof value!=='object') return JSON.stringify(value);
 if(Array.isArray(value)) return '['+value.map(canonicalJson).join(',')+']';
 return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonicalJson(value[k])).join(',')+'}';
}
export async function sha256(value:string):Promise<string> {
 const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value));
 return Array.from(new Uint8Array(digest),v=>v.toString(16).padStart(2,'0')).join('');
}
