import {ApiError} from '../errors.ts';
import {boundedBytes} from './images.ts';
import {validateLines} from './mapping.ts';
import type {OcrLine} from './mapping.ts';
export interface VisionConfig {project:string;credentials:any;timeoutMs:number;endpoint:string;workerSecret:string;localMock:boolean}
export interface OcrProvider {authorize?():Promise<void>;recognize(bytes:Uint8Array,requestId:string,accepted:()=>Promise<void>):Promise<OcrLine[]>}
export class VisionFailure extends ApiError {retryable:boolean;constructor(code:string,retryable:boolean){super(code);this.retryable=retryable;}}
export function readVisionEnvironment(get:(name:string)=>string|undefined):VisionConfig{
 const endpoint=get('GOOGLE_CLOUD_VISION_ENDPOINT')||'https://vision.googleapis.com',project=get('GOOGLE_CLOUD_PROJECT_ID')||'',workerSecret=get('QIYADAT_WORKER_SECRET')||'';
 const timeoutMs=Number(get('GOOGLE_CLOUD_VISION_TIMEOUT_MS')||'20000');let credentials:any;
 try{credentials=JSON.parse(get('GOOGLE_CLOUD_VISION_CREDENTIALS_JSON')||'');}catch{throw new ApiError('FEATURE_DISABLED');}
 const target=new URL(endpoint),supabase=new URL(get('SUPABASE_URL')||'https://invalid');
 const localMock=get('QIYADAT_LOCAL_TESTS')==='true'&&['kong','localhost','127.0.0.1','host.docker.internal'].includes(supabase.hostname)&&
  target.protocol==='http:'&&['localhost','127.0.0.1','host.docker.internal'].includes(target.hostname);
 if(target.pathname!=='/'||target.search||target.hash||target.username||target.password||(!localMock&&target.origin!=='https://vision.googleapis.com')||
  get('OCR_PROVIDER')!=='google_cloud_vision'||!/^[a-z][a-z0-9-]{4,62}$/.test(project)||workerSecret.length<32||!Number.isSafeInteger(timeoutMs)||timeoutMs<100||timeoutMs>30000)throw new ApiError('FEATURE_DISABLED');
 if(localMock){if(credentials.type!=='local_mock'||typeof credentials.access_token!=='string'||!credentials.access_token.startsWith('synthetic-'))throw new ApiError('FEATURE_DISABLED');}
 else if(credentials.type!=='service_account'||credentials.project_id!==project||!/^[-a-zA-Z0-9@.]+\.iam\.gserviceaccount\.com$/.test(credentials.client_email)||
  credentials.token_uri!=='https://oauth2.googleapis.com/token'||typeof credentials.private_key!=='string'||!credentials.private_key.startsWith('-----BEGIN PRIVATE KEY-----'))throw new ApiError('FEATURE_DISABLED');
 return {project,credentials,timeoutMs,endpoint:target.origin,workerSecret,localMock};
}
function base64(bytes:Uint8Array){let result='';for(let at=0;at<bytes.length;at+=8192)result+=String.fromCharCode(...bytes.subarray(at,at+8192));return btoa(result);}
const encoder=new TextEncoder();
const url64=(bytes:Uint8Array)=>base64(bytes).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
async function responseJson(response:Response,maximum=1048576){
 try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(await boundedBytes(response.body,maximum)));}
 catch(error){if(error instanceof VisionFailure)throw error;if(error instanceof ApiError&&error.code==='PROVIDER_UNAVAILABLE')throw new VisionFailure('PROVIDER_UNAVAILABLE',true);throw new VisionFailure('OCR_FAILED',false);}
}
export function visionLines(payload:any):OcrLine[]{
 if(!Array.isArray(payload?.responses)||payload.responses.length!==1)throw new VisionFailure('OCR_FAILED',false);
 const result=payload.responses[0];if(!result||typeof result!=='object')throw new VisionFailure('OCR_FAILED',false);
 if(result.error){const code=result.error.code;throw new VisionFailure(code===8?'GLOBAL_QUOTA_EXHAUSTED':code===13||code===14?'PROVIDER_UNAVAILABLE':'OCR_FAILED',code===13||code===14);}
 const full=result.fullTextAnnotation;if(!full){if(Object.keys(result).length===0)return [];throw new VisionFailure('OCR_FAILED',false);}
 if(typeof full.text!=='string'||full.text.length>200000)throw new VisionFailure('OCR_FAILED',false);
 if(!full.pages)return validateLines(full.text.split(/\r?\n/).map((text:string)=>({text,confidence:null})));
 if(!Array.isArray(full.pages)||full.pages.length>1)throw new VisionFailure('OCR_FAILED',false);
 const lines:OcrLine[]=[];
 for(const page of full.pages){if(!Array.isArray(page.blocks))throw new VisionFailure('OCR_FAILED',false);
  for(const block of page.blocks){if(!Array.isArray(block.paragraphs))throw new VisionFailure('OCR_FAILED',false);
   for(const paragraph of block.paragraphs){if(!Array.isArray(paragraph.words))throw new VisionFailure('OCR_FAILED',false);
    let text='',confidences:number[]=[];
    const flush=()=>{if(text.length){lines.push({text,confidence:confidences.length?confidences.reduce((a,b)=>a+b,0)/confidences.length:null});text='';confidences=[];}};
    for(const word of paragraph.words){if(!Array.isArray(word.symbols))throw new VisionFailure('OCR_FAILED',false);
     if(word.confidence!==undefined){if(!Number.isFinite(word.confidence)||word.confidence<0||word.confidence>1)throw new VisionFailure('OCR_FAILED',false);confidences.push(word.confidence);}
     for(const symbol of word.symbols){if(typeof symbol.text!=='string'||symbol.text.length>100)throw new VisionFailure('OCR_FAILED',false);text+=symbol.text;
      const type=symbol.property?.detectedBreak?.type;
      if(type==='SPACE'||type==='SURE_SPACE')text+=' ';
      if(type==='HYPHEN'){text+='-';flush();}
      else if(type==='LINE_BREAK'||type==='EOL_SURE_SPACE')flush();
     }
    }flush();
   }
  }
 }
 // A disagreement must not silently discard extra lines from either view.
 const flattened=lines.map(l=>l.text).join('').replace(/\s/g,'');
 if(flattened!==full.text.replace(/\s/g,'')){
  const fallback:OcrLine[]=full.text.split(/\r?\n/).map((text:string)=>({text,confidence:null})),remaining=new Map<string,number>();
  for(const line of fallback){const normalized=line.text.replace(/\s/g,'');remaining.set(normalized,(remaining.get(normalized)??0)+1);}
  for(const line of lines){const normalized=line.text.replace(/\s/g,''),count=remaining.get(normalized)??0;
   if(count>0)remaining.set(normalized,count-1);else if(normalized)fallback.push({text:line.text,confidence:null});}
  return validateLines(fallback);
 }
 return validateLines(lines);
}
export class VisionProvider implements OcrProvider {
 config:VisionConfig;fetcher:typeof fetch;cachedToken?:string;tokenUntil=0;
 constructor(config:VisionConfig,fetcher:typeof fetch=fetch){this.config=config;this.fetcher=fetcher;}
 async authorize(){await this.accessToken();}
 async accessToken(){
  if(this.config.localMock)return this.config.credentials.access_token;
  if(this.cachedToken&&this.tokenUntil>Date.now()+60000)return this.cachedToken;
  const c=this.config.credentials,iat=Math.floor(Date.now()/1000);let assertion:string;
  try{const pem=c.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,'');
   const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(pem),v=>v.charCodeAt(0)),{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['sign']);
   const input=url64(encoder.encode(JSON.stringify({alg:'RS256',typ:'JWT'})))+'.'+url64(encoder.encode(JSON.stringify({iss:c.client_email,
    scope:'https://www.googleapis.com/auth/cloud-vision',aud:'https://oauth2.googleapis.com/token',iat,exp:iat+3600})));
   assertion=input+'.'+url64(new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5',key,encoder.encode(input))));
  }catch{throw new VisionFailure('FEATURE_DISABLED',false);}
  let response:Response;
  try{response=await this.fetcher('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
   body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion}),signal:AbortSignal.timeout(this.config.timeoutMs)});}catch{throw new VisionFailure('PROVIDER_UNAVAILABLE',true);}
  if(!response.ok){await response.body?.cancel();throw new VisionFailure('PROVIDER_UNAVAILABLE',response.status>=500);}
  const token=await responseJson(response,32768);
  if(typeof token.access_token!=='string'||!token.access_token||token.token_type!=='Bearer'||!Number.isFinite(token.expires_in)||token.expires_in<60||token.expires_in>3600)throw new VisionFailure('PROVIDER_UNAVAILABLE',false);
  this.cachedToken=token.access_token;this.tokenUntil=Date.now()+token.expires_in*1000;return this.cachedToken!;
 }
 async recognize(bytes:Uint8Array,requestId:string,accepted:()=>Promise<void>){
  const token=await this.accessToken();let response:Response;
  try{response=await this.fetcher(this.config.endpoint+'/v1/images:annotate',{method:'POST',headers:{Authorization:'Bearer '+token,
   'Content-Type':'application/json','x-goog-user-project':this.config.project,'X-Request-Id':requestId},
   body:JSON.stringify({requests:[{image:{content:base64(bytes)},features:[{type:'DOCUMENT_TEXT_DETECTION'}],imageContext:{languageHints:['en']}}]}),
   signal:AbortSignal.timeout(this.config.timeoutMs)});}catch{throw new VisionFailure('PROVIDER_UNAVAILABLE',true);}
  if(!response.ok){await response.body?.cancel();throw new VisionFailure(response.status===429?'GLOBAL_QUOTA_EXHAUSTED':response.status>=500?'PROVIDER_UNAVAILABLE':'OCR_FAILED',response.status>=500);}
  try{await accepted();}catch(error){await response.body?.cancel();throw error;}return visionLines(await responseJson(response));
 }
}
