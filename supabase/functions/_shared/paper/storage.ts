import {ApiError} from '../errors.ts';
import type {Environment} from '../env.ts';
import {assertImagePath,boundedBytes,MAX_IMAGE,safePath} from './images.ts';
import type {PaperImage} from './images.ts';
export class PaperStorage {
 env:Environment;fetcher:typeof fetch;
 constructor(env:Environment,fetcher:typeof fetch=fetch){this.env=env;this.fetcher=fetcher;}
 async call(path:string,method:string,body?:BodyInit,contentType?:string){
  const headers=new Headers({apikey:this.env.serviceKey});if(this.env.serviceKey.startsWith('eyJ'))headers.set('Authorization','Bearer '+this.env.serviceKey);
  if(contentType)headers.set('Content-Type',contentType);
  try{return await this.fetcher(this.env.url+'/storage/v1'+path,{method,headers,body,signal:AbortSignal.timeout(15000)});}catch{throw new ApiError('PROVIDER_UNAVAILABLE');}
 }
 async download(image:PaperImage){assertImagePath(image);const r=await this.call('/object/authenticated/paper-uploads/'+image.object_path,'GET');
  if(!r.ok){await r.body?.cancel();throw new ApiError([400,404].includes(r.status)?'PAPER_UPLOAD_INCOMPLETE':'PROVIDER_UNAVAILABLE');}
  return boundedBytes(r.body,MAX_IMAGE);
 }
 async upload(image:PaperImage,bytes:Uint8Array){assertImagePath(image);const r=await this.call('/object/paper-uploads/'+image.object_path,'POST',bytes,image.content_type);
  await r.body?.cancel();if(!r.ok)throw new ApiError(r.status===409?'SESSION_STATE_CONFLICT':'PROVIDER_UNAVAILABLE');
 }
 async remove(path:string,bucket='paper-uploads'){
  if(bucket!=='paper-uploads'||!safePath(path))throw new ApiError('INTERNAL_ERROR');
  const r=await this.call('/object/paper-uploads','DELETE',JSON.stringify({prefixes:[path]}),'application/json');
  await r.body?.cancel();if(!r.ok)throw new ApiError('PROVIDER_UNAVAILABLE');
 }
}
