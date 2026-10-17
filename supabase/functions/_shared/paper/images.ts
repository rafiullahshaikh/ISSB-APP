import {ApiError} from '../errors.ts';
export const MAX_IMAGE=8388608,MAX_TOTAL=25165824;
export interface PaperImage {id:string;user_id:string;session_id:string;bucket_id:string;object_path:string;content_type:string;size_bytes:number;sha256:string;expires_at:string;upload_expires_at:string;uploaded_at?:string;status?:string}
const uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
export function safePath(path:string){return new RegExp('^paper-pages/'+uuid+'/'+uuid+'/'+uuid+'\\.(jpg|png|webp)$').test(path);}
export function assertImagePath(image:PaperImage){
 const ext=image.content_type==='image/jpeg'?'jpg':image.content_type==='image/png'?'png':image.content_type==='image/webp'?'webp':'';
 if(!ext||image.bucket_id!=='paper-uploads'||!safePath(image.object_path)||image.object_path!==`paper-pages/${image.user_id}/${image.session_id}/${image.id}.${ext}`)throw new ApiError('PAPER_UPLOAD_INCOMPLETE');
}
export async function boundedBytes(body:ReadableStream<Uint8Array>|null,maximum:number,timeoutMs=15000):Promise<Uint8Array>{
 if(!body)throw new ApiError('PAPER_UPLOAD_INCOMPLETE');
 const reader=body.getReader(),chunks:Uint8Array[]=[];let length=0,timer:ReturnType<typeof setTimeout>|undefined;
 const timeout=new Promise<never>((_,reject)=>{timer=setTimeout(()=>{reject(new ApiError('PROVIDER_UNAVAILABLE'));void reader.cancel().catch(()=>{});},timeoutMs);});
 try{while(true){const part=await Promise.race([reader.read(),timeout]);if(part.done)break;length+=part.value.byteLength;
   if(length>maximum){await reader.cancel();throw new ApiError('UPLOAD_TOO_LARGE');}chunks.push(part.value);}
 }finally{clearTimeout(timer);reader.releaseLock();}
 const result=new Uint8Array(length);let offset=0;for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}return result;
}
function invalid():never{throw new ApiError('UNSUPPORTED_MEDIA_TYPE');}
function dimensions(width:number,height:number){if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>0x7fffffff||height>0x7fffffff)invalid();}
function text(bytes:Uint8Array){return String.fromCharCode(...bytes);}
const crcTable=Uint32Array.from({length:256},(_,n)=>{let value=n;for(let i=0;i<8;i++)value=(value>>>1)^((value&1)?0xedb88320:0);return value;});
function crc(bytes:Uint8Array){let value=0xffffffff;for(const b of bytes)value=(value>>>8)^crcTable[(value^b)&255];return (value^0xffffffff)>>>0;}
function png(bytes:Uint8Array){
 const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);let at=8,header=false,data=false,endedData=false;
 while(at+12<=bytes.length){const length=view.getUint32(at),type=text(bytes.subarray(at+4,at+8));if(length>MAX_IMAGE||at+12+length>bytes.length)invalid();
  if(view.getUint32(at+8+length)!==crc(bytes.subarray(at+4,at+8+length)))invalid();
  if(!header){if(type!=='IHDR'||length!==13)invalid();dimensions(view.getUint32(at+8),view.getUint32(at+12));
   const depth=bytes[at+16],color=bytes[at+17];
   if(!({0:[1,2,4,8,16],2:[8,16],3:[1,2,4,8],4:[8,16],6:[8,16]} as Record<number,number[]>)[color]?.includes(depth)||bytes[at+18]!==0||bytes[at+19]!==0||bytes[at+20]>1)invalid();header=true;
  }else if(type==='IHDR')invalid();
  else if(type==='IDAT'){if(endedData)invalid();data=true;}
  else if(type==='IEND'){if(length!==0||!data||at+12!==bytes.length)invalid();return;}
  else {if(data)endedData=true;if(!['PLTE','tRNS','sRGB','gAMA','cHRM','pHYs'].includes(type))invalid();}
  at+=12+length;
 }invalid();
}
function jpeg(bytes:Uint8Array){let at=2,frame=false,scan=false;const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
 while(at<bytes.length){if(bytes[at++]!==255)invalid();while(bytes[at]===255)at++;const marker=bytes[at++];
  if(marker===217){if(!frame||!scan||at!==bytes.length)invalid();return;}
  if(marker===216||marker===0||marker===1||marker>=208&&marker<=215)invalid();
  if(at+2>bytes.length)invalid();const size=view.getUint16(at);if(size<2||at+size>bytes.length)invalid();
  if(marker>=225&&marker<=239||marker===254)invalid();
  if([192,193,194].includes(marker)){if(size<8)invalid();dimensions(view.getUint16(at+5),view.getUint16(at+3));frame=true;}
  else if(![196,219,221,218,224].includes(marker))invalid();
  at+=size;
  if(marker===218){if(!frame)invalid();scan=true;
   while(at<bytes.length){if(bytes[at]!==255){at++;continue;}const next=bytes[at+1];if(next===0||next>=208&&next<=215){at+=2;continue;}break;}
  }
 }invalid();
}
function webp(bytes:Uint8Array){const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);if(bytes.length<20||view.getUint32(4,true)+8!==bytes.length)invalid();
 let at=12,pixels=0;
 while(at+8<=bytes.length){const type=text(bytes.subarray(at,at+4)),size=view.getUint32(at+4,true),start=at+8;
  if(size>MAX_IMAGE||start+size+(size%2)>bytes.length)invalid();
  if(type==='VP8 '){if(size<10||text(bytes.subarray(start+3,start+6))!=='\x9d\x01\x2a')invalid();dimensions(view.getUint16(start+6,true)&0x3fff,view.getUint16(start+8,true)&0x3fff);pixels++;}
  else if(type==='VP8L'){if(size<5||bytes[start]!==47)invalid();const bits=view.getUint32(start+1,true);dimensions((bits&0x3fff)+1,((bits>>>14)&0x3fff)+1);pixels++;}
  else if(type==='VP8X'){if(size!==10||bytes[start]&0x0e)invalid();const dim=(n:number)=>1+bytes[n]+(bytes[n+1]<<8)+(bytes[n+2]<<16);dimensions(dim(start+4),dim(start+7));}
  else if(type!=='ALPH')invalid();
  if(size%2&&bytes[start+size]!==0)invalid();at=start+size+(size%2);
 }if(at!==bytes.length||pixels!==1)invalid();
}
export function validateFormat(bytes:Uint8Array,mime:string){
 if(mime==='image/png'&&bytes.length>=8&&text(bytes.subarray(0,8))==='\x89PNG\r\n\x1a\n')return png(bytes);
 if(mime==='image/jpeg'&&bytes[0]===255&&bytes[1]===216)return jpeg(bytes);
 if(mime==='image/webp'&&text(bytes.subarray(0,4))==='RIFF'&&text(bytes.subarray(8,12))==='WEBP')return webp(bytes);
 invalid();
}
export async function validateImage(image:PaperImage,bytes:Uint8Array,now=Date.now()){
 assertImagePath(image);if(Date.parse(image.expires_at)<=now)throw new ApiError('UPLOAD_EXPIRED');
 if(bytes.length>MAX_IMAGE||image.size_bytes>MAX_IMAGE)throw new ApiError('UPLOAD_TOO_LARGE');
 if(bytes.length!==Number(image.size_bytes))throw new ApiError('PAPER_UPLOAD_INCOMPLETE');
 const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 if(digest!==image.sha256)throw new ApiError('PAPER_UPLOAD_INCOMPLETE');
 validateFormat(bytes,image.content_type);
}
