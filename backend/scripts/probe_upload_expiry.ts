import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
// Investigation only: never used by the API. A user JWT in a URL is not an
// upload-only capability and must not be returned by a preparation endpoint.
async function signUpload(config:any,path:string,contentType:string,expiresAt:string,now=new Date()){
 const encode=(value:string)=>encodeURIComponent(value).replace(/[!'()*]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
 const hex=(bytes:Uint8Array)=>Buffer.from(bytes).toString('hex');
 const {createHash,createHmac}=await import('node:crypto');
 const stamp=now.toISOString().replace(/[-:]|\.\d{3}/g,''),day=stamp.slice(0,8),scope=day+'/'+config.region+'/s3/aws4_request';
 const seconds=Math.floor((Date.parse(expiresAt)-now.getTime())/1000);
 assert.ok(seconds>0&&seconds<=900);
 const url=new URL(config.endpoint+'/paper-uploads/'+path);
 const query:Record<string,string>={'X-Amz-Algorithm':'AWS4-HMAC-SHA256','X-Amz-Credential':config.accessKey+'/'+scope,
  'X-Amz-Date':stamp,'X-Amz-Expires':String(seconds),'X-Amz-SignedHeaders':'content-type;host','X-Amz-Security-Token':config.sessionToken};
 const canonicalQuery=Object.keys(query).sort().map(k=>encode(k)+'='+encode(query[k])).join('&');
 const canonical=['PUT',url.pathname,canonicalQuery,'content-type:'+contentType+'\nhost:'+url.host+'\n','content-type;host','UNSIGNED-PAYLOAD'].join('\n');
 const hmac=(key:string|Uint8Array,value:string)=>createHmac('sha256',key).update(value).digest();
 let key=hmac('AWS4'+config.secretKey,day);key=hmac(key,config.region);key=hmac(key,'s3');key=hmac(key,'aws4_request');
 url.search=canonicalQuery+'&X-Amz-Signature='+hex(hmac(key,'AWS4-HMAC-SHA256\n'+stamp+'\n'+scope+'\n'+createHash('sha256').update(canonical).digest('hex')));
 return url.toString();
}
let local:any;
try{local=JSON.parse(execFileSync(process.execPath,[join(process.env.USERPROFILE!,'node_modules/supabase/dist/supabase.js'),'status','-o','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:60000}));}
catch{throw new Error('Local Supabase status is unavailable.');}
assert.equal(local.API_URL,'http://127.0.0.1:55321');
const base=local.API_URL;
const headers={apikey:local.SERVICE_ROLE_KEY,Authorization:'Bearer '+local.SERVICE_ROLE_KEY,'Content-Type':'application/json'};
let owner:string|undefined,foreign:string|undefined,path:string|undefined;
async function request(route:string,method='GET',body?:unknown,custom=headers){
 const response=await fetch(base+route,{method,headers:custom,body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(60000)});
 const text=await response.text();assert.ok(response.ok,'Local synthetic setup succeeds: '+response.status);return text?JSON.parse(text):null;
}
async function identity(){const email='qiyadat-expiry-'+randomUUID()+'@example.invalid',password=randomUUID()+randomUUID();
 const user=await request('/auth/v1/admin/users','POST',{email,password,email_confirm:true});
 const login=await request('/auth/v1/token?grant_type=password','POST',{email,password},{apikey:local.ANON_KEY,'Content-Type':'application/json'});
 return {id:user.id,token:login.access_token};
}
try{
 console.log('Checking synthetic local Auth setup.');
 const a=await identity();owner=a.id;const b=await identity();foreign=b.id;
 const config=await request('/rest/v1/rpc/qiyadat_public_config','POST',{p_kind:'diagnostic'});
 const start=await request('/rest/v1/rpc/qiyadat_mutate','POST',{p_actor:a.id,p_operation:'start',p_key:randomUUID(),p_body:{client_session_id:randomUUID(),set_id:config.set.id,set_version:1,kind:'diagnostic',practice_mode:'training',response_mode:'paper',session_size:20}});
 const session=start.body.data.id;
 await request('/rest/v1/rpc/qiyadat_mutate','POST',{p_actor:a.id,p_operation:'finish',p_session_id:session,p_key:randomUUID(),p_body:{reason:'manual'}});
 const upload=randomUUID();path=a.id+'/'+session+'/'+upload+'.png';
 await request('/rest/v1/paper_uploads','POST',{id:upload,user_id:a.id,session_id:session,page_number:1,content_type:'image/png',size_bytes:8,sha256:'0'.repeat(64),object_path:path});
 console.log('Checking scoped Storage signatures.');
 const signing={endpoint:base+'/storage/v1/s3',region:'local',accessKey:'stub',secretKey:local.ANON_KEY,sessionToken:a.token};
 const now=new Date(),expiry=new Date(now.getTime()+900000).toISOString();
 const url=await signUpload(signing,path,'image/png',expiry,now);
 assert.equal(new URL(url).searchParams.get('X-Amz-Expires'),'900');
 const bytes=new Uint8Array([137,80,78,71,13,10,26,10]);
 async function put(target:string){return fetch(target,{method:'PUT',headers:{'Content-Type':'image/png'},body:bytes,signal:AbortSignal.timeout(15000)});}
 const denied=await put(await signUpload({...signing,sessionToken:b.token},path,'image/png',expiry,now));
 assert.ok(!denied.ok,'Foreign user cannot use prepared path');await denied.body?.cancel();
 const old=new Date(now.getTime()-901000);
 const expired=await put(await signUpload(signing,path,'image/png',new Date(old.getTime()+900000).toISOString(),old));
 assert.ok(!expired.ok,'Expired signature is rejected');await expired.body?.cancel();
 const uploaded=await put(url);const result=await uploaded.text();
 assert.equal(uploaded.status,403,'Existing insert-only policies reject S3 upsert');
 assert.ok(result.includes('AccessDenied')&&result.includes('row-level security'),'Failure is RLS, not signature generation');
 console.log('PASS: user-scoped S3 PUT is denied by preserved insert-only Storage policies.');
 const signed=await request('/storage/v1/object/upload/sign/paper-uploads/'+path,'POST',{},
  {apikey:local.ANON_KEY,Authorization:'Bearer '+a.token,'Content-Type':'application/json'});
 const claims=JSON.parse(Buffer.from(signed.token.split('.')[1],'base64url').toString('utf8'));
 assert.equal(claims.exp-claims.iat,7200,'Standard signed upload token lasts two hours');
 console.log('PASS: issued standard upload token has a 7200-second lifetime, not 900.');
 await request('/rest/v1/paper_uploads?id=eq.'+upload,'PATCH',{status:'delete_pending'});
 const transport=await put(base+'/storage/v1'+signed.url);
 assert.ok(transport.ok,'Signed transport bypasses now-inactive authorization RLS');await transport.body?.cancel();
 console.log('PASS: standard signed PUT still accepts bytes after its authorization is made inactive.');
 const read=await fetch(base+'/storage/v1/object/authenticated/paper-uploads/'+path,{headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+a.token},signal:AbortSignal.timeout(15000)});
 assert.ok(!read.ok,'Upload permission does not grant reading');await read.body?.cancel();
 console.log('PASS: private object read remains denied. These findings characterize a blocker, not Phase 4 completion.');
}finally{
 if(path)await request('/storage/v1/object/paper-uploads','DELETE',{prefixes:[path]});
 for(const id of [owner,foreign])if(id)await request('/auth/v1/admin/users/'+id,'DELETE');
}
