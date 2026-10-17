import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {localStatus} from '../../../backend/scripts/local_supabase_cli.ts';
import {imageBytes,fixtures} from './paper_fixtures.ts';
const base='http://127.0.0.1:55321',api=base+'/functions/v1/api/v1';
interface Actor{id:string;token:string}
test('private paper relay, durable Vision OCR, correction, deletion and existing feedback',async t=>{
 const local=localStatus();assert.ok(process.env.QIYADAT_TEST_WORKER_SECRET,'Use test:ocr:http for synthetic providers.');
 const serviceHeaders={apikey:local.SERVICE_ROLE_KEY,Authorization:'Bearer '+local.SERVICE_ROLE_KEY,'Content-Type':'application/json'};
 const users:string[]=[],settings=new Map<string,any>(),secrets:string[]=Object.values(fixtures),paths:string[]=[];let storageStopped=false;
 const request=(path:string,init:RequestInit={})=>fetch(base+path,{...init,signal:AbortSignal.timeout(60000)});
 async function service(path:string,method='GET',body?:unknown){const r=await request('/rest/v1/'+path,{method,headers:serviceHeaders,body:body===undefined?undefined:JSON.stringify(body)});
  assert.ok(r.ok,'Synthetic fixture request succeeds: '+r.status);const text=await r.text();return text?JSON.parse(text):null;}
 async function setting(name:string,value:any){if(!settings.has(name))settings.set(name,(await service('app_settings?key=eq.'+name+'&select=value'))[0].value);await service('app_settings?key=eq.'+name,'PATCH',{value});}
 async function actor():Promise<Actor>{const email='qiyadat-phase4-'+randomUUID()+'@example.invalid',password=randomUUID()+randomUUID();
  const r=await request('/auth/v1/admin/users',{method:'POST',headers:serviceHeaders,body:JSON.stringify({email,password,email_confirm:true})});assert.equal(r.status,200);const user=await r.json();users.push(user.id);
  const login=await request('/auth/v1/token?grant_type=password',{method:'POST',headers:{apikey:local.ANON_KEY,'Content-Type':'application/json'},body:JSON.stringify({email,password})});assert.equal(login.status,200);const token=(await login.json()).access_token;secrets.push(token,email);return {id:user.id,token};
 }
 async function call(path:string,user?:Actor,method='GET',body?:unknown,key?:string){const r=await fetch(api+path,{method,headers:{apikey:local.ANON_KEY,...(user?{Authorization:'Bearer '+user.token}:{}),
  ...(body===undefined?{}:{'Content-Type':'application/json'}),...(key?{'Idempotency-Key':key}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(60000)});
  return {status:r.status,body:await r.json(),headers:r.headers};}
 function check(result:any,status:number,code?:string){assert.equal(result.status,status,code||'HTTP status');if(code)assert.equal(result.body.error.code,code);}
 async function start(user:Actor){const config=(await call('/config/wat?kind=diagnostic')).body.data;
  const result=await call('/wat/sessions',user,'POST',{client_session_id:randomUUID(),set_id:config.set.id,set_version:1,kind:'diagnostic',practice_mode:'training',response_mode:'paper',session_size:20},randomUUID());check(result,201);
  const id=result.body.data.id;check(await call('/wat/sessions/'+id+'/finish',user,'POST',{reason:'manual'},randomUUID()),200);return id as string;
 }
 async function metadata(mime:keyof typeof fixtures,page=1,bytes=imageBytes(mime)){return {page_number:page,file_name:'page-'+page+(mime==='image/jpeg'?'.jpg':mime==='image/png'?'.png':'.webp'),
  content_type:mime,size_bytes:bytes.length,sha256:Buffer.from(await crypto.subtle.digest('SHA-256',bytes)).toString('hex')};}
 async function prepare(user:Actor,id:string,types:(keyof typeof fixtures)[]){const files=await Promise.all(types.map((mime,i)=>metadata(mime,i+1)));
  const result=await call('/wat/sessions/'+id+'/paper/uploads',user,'POST',{files});check(result,201);
  for(const u of result.body.data.uploads){secrets.push(u.upload_url,new URL(u.upload_url).searchParams.get('token')!);}
  const records=await service('paper_uploads?session_id=eq.'+id+'&select=object_path');for(const r of records){paths.push(r.object_path);secrets.push(r.object_path);}
  return result.body.data.uploads as any[];
 }
 async function upload(url:string,user:Actor,mime:string,bytes:Uint8Array){const r=await fetch(url,{method:'PUT',headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+user.token,'Content-Type':mime},body:bytes,signal:AbortSignal.timeout(60000)});
  const text=await r.text();return {status:r.status,body:text?JSON.parse(text):null,headers:r.headers};}
 async function worker(name='ocr-worker',token=process.env.QIYADAT_TEST_WORKER_SECRET!){const r=await request('/functions/v1/'+name,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:'{}'});return {status:r.status,body:await r.json()};}
 async function mode(value:string){const r=await fetch('http://127.0.0.1:'+process.env.QIYADAT_TEST_VISION_PORT+'/control',{method:'POST',headers:{'Content-Type':'application/json','x-mock-control':process.env.QIYADAT_TEST_VISION_CONTROL!},body:JSON.stringify({mode:value})});assert.ok(r.ok);return r.json();}
 async function storageReady(){for(let n=0;n<60;n++){try{if(execFileSync('docker',['inspect','supabase_storage_qiyadat-local','--format','{{.State.Health.Status}}'],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim()==='healthy')return;}catch{}await new Promise(resolve=>setTimeout(resolve,1000));}throw new Error('Local Storage did not recover.');}
 async function stored(path:string){return request('/storage/v1/object/authenticated/paper-uploads/'+path,{headers:serviceHeaders});}
 const confirm=(revision:number,text='PRIVATE-CONFIRMED: A person takes a practical step.')=>({ocr_revision:revision,responses:Array.from({length:20},(_,i)=>({position:i+1,confirmed_text:i===0?text:''}))});
 let a:Actor,b:Actor,c:Actor,session:string,other:string,uploads:any[],job:string,body:any,key:string;
 try{
  a=await actor();b=await actor();c=await actor();session=await start(a);other=await start(b);
  const begins=new Date(Date.now()-1000);await service('entitlements','POST',{user_id:c.id,type:'founding_30d',starts_at:begins.toISOString(),expires_at:new Date(begins.getTime()+30*86400000).toISOString()});
  await t.test('new routes reject missing and invalid user authentication',async()=>{for(const path of ['/wat/sessions/'+session+'/paper/ocr','/wat/sessions/'+session+'/paper/uploads']){
   const method=path.endsWith('uploads')?'POST':'GET';check(await call(path,undefined,method,method==='POST'?{files:[]}:undefined),401,'AUTH_REQUIRED');check(await call(path,{id:a.id,token:'invalid'},method,method==='POST'?{files:[]}:undefined),401,'AUTH_INVALID');}});
  await t.test('OCR disabled prevents preparation',async()=>{check(await call('/wat/sessions/'+session+'/paper/uploads',a,'POST',{files:[await metadata('image/png')]}),503,'FEATURE_DISABLED');await setting('ocr_enabled',true);});
  await t.test('foreign prepare and draft are hidden',async()=>{check(await call('/wat/sessions/'+session+'/paper/uploads',b,'POST',{files:[await metadata('image/png')]}),404,'NOT_FOUND');check(await call('/wat/sessions/'+session+'/paper/ocr',b),404,'NOT_FOUND');});
  await t.test('metadata bounds, ordering and unknown properties are rejected',async()=>{
   const file=await metadata('image/png');for(const invalid of [{files:[file],user_id:b.id},{files:[{...file,object_path:'../other'}]}])check(await call('/wat/sessions/'+session+'/paper/uploads',a,'POST',invalid),422,'VALIDATION_ERROR');
   check(await call('/wat/sessions/'+session+'/paper/uploads',a,'POST',{files:[{...file,page_number:2}]}),422,'VALIDATION_ERROR');
   check(await call('/wat/sessions/'+session+'/paper/uploads',a,'POST',{files:[{...file,size_bytes:8388609}]}),413,'UPLOAD_TOO_LARGE');
   check(await call('/wat/sessions/'+session+'/paper/uploads',a,'POST',{files:Array.from({length:4},(_,i)=>({...file,page_number:i+1,size_bytes:8388608}))}),413,'UPLOAD_TOO_LARGE');
  });
  await t.test('two ordered pages get protected capabilities with fifteen-minute expiry',async()=>{uploads=await prepare(a,session,['image/png','image/jpeg']);assert.equal(uploads.length,2);
   for(const u of uploads){assert.equal(u.method,'PUT');assert.ok(u.upload_url.startsWith(api+'/wat/sessions/'+session+'/paper/uploads/'));assert.ok(!u.upload_url.includes(a.token));assert.ok(Date.parse(u.expires_at)-Date.now()<=900000);}
   const repeat=await prepare(a,session,['image/png','image/jpeg']);assert.deepEqual(repeat,uploads);
  });
  await t.test('foreign owner and tampered capabilities cannot upload',async()=>{
   check(await upload(uploads[0].upload_url,b,'image/png',imageBytes()),404,'NOT_FOUND');const url=new URL(uploads[0].upload_url);url.searchParams.set('token','0'.repeat(64));check(await upload(url.toString(),a,'image/png',imageBytes()),403,'FORBIDDEN');
  });
  await t.test('spoofed type, wrong size and checksum are rejected before Storage',async()=>{
   check(await upload(uploads[0].upload_url,a,'image/jpeg',imageBytes()),415,'UNSUPPORTED_MEDIA_TYPE');check(await upload(uploads[0].upload_url,a,'image/png',imageBytes().slice(0,-1)),422,'PAPER_UPLOAD_INCOMPLETE');
   const changed=imageBytes();changed[20]^=1;check(await upload(uploads[0].upload_url,a,'image/png',changed),422,'PAPER_UPLOAD_INCOMPLETE');
  });
  await t.test('direct Storage upload cannot bypass relay validation',async()=>{
   const rows=await service('paper_uploads?session_id=eq.'+session+'&select=object_path&page_number=eq.1');const r=await request('/storage/v1/object/paper-uploads/'+rows[0].object_path,{method:'POST',headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+a.token,'Content-Type':'image/png'},body:imageBytes()});assert.ok(!r.ok);await r.body?.cancel();
  });
  await t.test('concurrent identical uploads cannot overwrite one another',async()=>{
   const results=await Promise.all(Array.from({length:3},()=>upload(uploads[0].upload_url,a,'image/png',imageBytes())));assert.ok(results.some(r=>r.status===204));results.forEach(r=>assert.ok([204,409].includes(r.status)));
   check(await upload(uploads[1].upload_url,a,'image/jpeg',imageBytes('image/jpeg')),204);
  });
  await t.test('private images deny public and cross-user reads',async()=>{
   const rows=await service('paper_uploads?session_id=eq.'+session+'&select=object_path');for(const r of rows){for(const path of ['/storage/v1/object/public/paper-uploads/','/storage/v1/object/authenticated/paper-uploads/']){
    const response=await request(path+r.object_path,{headers:{apikey:local.ANON_KEY,Authorization:'Bearer '+b.token}});assert.ok(!response.ok);await response.body?.cancel();}}
  });
  await t.test('OCR requires every ordered page, valid IDs and an idempotency header',async()=>{
   body={upload_ids:uploads.map(u=>u.upload_id),language:'en'};check(await call('/wat/sessions/'+session+'/paper/ocr',a,'POST',body),422,'VALIDATION_ERROR');
   for(const ids of [[uploads[0].upload_id],[uploads[0].upload_id,uploads[0].upload_id],[randomUUID(),uploads[1].upload_id]])check(await call('/wat/sessions/'+session+'/paper/ocr',a,'POST',{...body,upload_ids:ids},randomUUID()),422,'PAPER_UPLOAD_INCOMPLETE');
   check(await call('/wat/sessions/'+session+'/paper/ocr',b,'POST',body,randomUUID()),404,'NOT_FOUND');
  });
  await t.test('concurrent duplicate OCR requests queue one job and two page units',async()=>{
   key=randomUUID();const results=await Promise.all(Array.from({length:3},()=>call('/wat/sessions/'+session+'/paper/ocr',a,'POST',body,key)));results.forEach(r=>{check(r,202);assert.deepEqual(r.body,results[0].body);});job=results[0].body.data.job_id;
   assert.equal((await service('usage_reservations?job_id=eq.'+job+'&select=id')).length,2);assert.equal((await service('processing_jobs?session_id=eq.'+session+'&type=eq.ocr&select=id')).length,1);
   check(await call('/wat/sessions/'+session+'/paper/ocr',a,'POST',{...body,language:'ur'},key),409,'IDEMPOTENCY_CONFLICT');
  });
  await t.test('paper feedback is rejected before candidate confirmation',async()=>{check(await call('/wat/sessions/'+session+'/report',a,'POST',{rubric_version:'wat-rubric-v1'},randomUUID()),409,'SESSION_STATE_CONFLICT');});
  await t.test('worker and job polling reject unauthorized access',async()=>{
   assert.equal((await worker('ocr-worker',local.ANON_KEY)).status,401);assert.equal((await worker('ocr-worker',a.token)).status,401);check(await call('/jobs/'+job,b),404,'NOT_FOUND');const poll=await call('/jobs/'+job,a);check(poll,200);assert.equal(poll.body.data.status,'queued');
  });
  await t.test('mocked Vision produces an editable twenty-row draft, never canonical answers',async()=>{
   check(await worker(),200);const poll=await call('/jobs/'+job,a);check(poll,200);assert.equal(poll.body.data.status,'succeeded');assert.equal(poll.body.data.result.ocr_revision,1);assert.equal(poll.body.data.result.next_action,'confirm_ocr');
   const draft=await call('/wat/sessions/'+session+'/paper/ocr',a);check(draft,200);assert.equal(draft.body.data.responses.length,20);assert.ok(draft.body.data.responses[0].ocr_text.includes('PRIVATE-OCR'));
   const canonical=await service('wat_responses?session_id=eq.'+session+'&select=answer,locked');assert.ok(canonical.every((r:any)=>r.answer===''&&!r.locked));assert.ok(!JSON.stringify(poll.body).includes('PRIVATE-OCR'));
  });
  await t.test('stale revision, foreign confirmation and incomplete positions are rejected',async()=>{
   check(await call('/wat/sessions/'+session+'/paper/confirm',a,'PUT',confirm(2)),409,'OCR_CONFIRMATION_STALE');check(await call('/wat/sessions/'+session+'/paper/confirm',b,'PUT',confirm(1)),404,'NOT_FOUND');
   const missing=confirm(1);missing.responses.pop();check(await call('/wat/sessions/'+session+'/paper/confirm',a,'PUT',missing),422,'OCR_TEXT_INCOMPLETE');
   const duplicate=confirm(1);duplicate.responses[19].position=1;check(await call('/wat/sessions/'+session+'/paper/confirm',a,'PUT',duplicate),422,'OCR_TEXT_INCOMPLETE');
  });
  await t.test('candidate correction is canonical and original images disappear immediately',async()=>{
   const result=await call('/wat/sessions/'+session+'/paper/confirm',a,'PUT',confirm(1));check(result,200);assert.deepEqual(result.body.data.images,{status:'deleted',delete_pending:false});
   const rows=await service('paper_uploads?session_id=eq.'+session+'&select=status,object_path');for(const row of rows){assert.equal(row.status,'deleted');const r=await stored(row.object_path);assert.ok(!r.ok);await r.body?.cancel();}
   assert.equal((await service('ocr_drafts?session_id=eq.'+session+'&select=id')).length,0);check(await upload(uploads[0].upload_url,a,'image/png',imageBytes()),409,'SESSION_STATE_CONFLICT');
  });
  await t.test('OCR replay still returns original result after images were deleted',async()=>{const result=await call('/wat/sessions/'+session+'/paper/ocr',a,'POST',body,key);check(result,202);assert.equal(result.body.data.job_id,job);});
  await t.test('existing report worker sees confirmed text only and preserves OCR response source',async()=>{
   const me=(await call('/me',a)).body.data;check(await call('/me',a,'PATCH',{accept_ai_processing_terms_version:me.ai_processing_consent.version}),200);await setting('feedback_enabled',true);
   check(await call('/wat/sessions/'+session+'/report',a,'POST',{rubric_version:'wat-rubric-v1'},randomUUID()),202);check(await worker('feedback-worker'),200);
   const report=await call('/wat/sessions/'+session+'/report',a);check(report,200);assert.equal(report.body.data.sentences[0].response_source,'ocr_confirmed');assert.equal(report.body.data.sentences[0].response,confirm(1).responses[0].confirmed_text);assert.ok(!JSON.stringify(report.body).includes('PRIVATE-OCR'));
   const detail=await call('/wat/sessions/'+session,a);assert.ok(!JSON.stringify(detail.body).includes('paper-pages/'));assert.ok(!JSON.stringify(detail.body).includes('object_path'));
  });
  let retryJob:string,retryBody:any,bUploads:any[];
  await t.test('WebP upload is supported and transient OCR fails after three fenced attempts',async()=>{
   bUploads=await prepare(b,other,['image/webp']);check(await upload(bUploads[0].upload_url,b,'image/webp',imageBytes('image/webp')),204);
   retryBody={upload_ids:bUploads.map(u=>u.upload_id),language:'en'};const queued=await call('/wat/sessions/'+other+'/paper/ocr',b,'POST',retryBody,randomUUID());check(queued,202);retryJob=queued.body.data.job_id;await mode('unavailable');
   for(let i=1;i<=3;i++){if(i>1)await service('processing_jobs?id=eq.'+retryJob,'PATCH',{next_attempt_at:new Date().toISOString()});check(await worker(),200);const poll=await call('/jobs/'+retryJob,b);assert.equal(poll.body.data.attempt,i);assert.equal(poll.body.data.status,i===3?'failed':'retrying');}
  });
  await t.test('technical OCR retry reuses the same canonical free session',async()=>{
   await mode('valid');const oldUpload=bUploads[0].upload_id;bUploads=await prepare(b,other,['image/webp']);assert.notEqual(bUploads[0].upload_id,oldUpload);
   check(await upload(bUploads[0].upload_url,b,'image/webp',imageBytes('image/webp')),204);retryBody={upload_ids:bUploads.map(u=>u.upload_id),language:'en'};
   const result=await call('/wat/sessions/'+other+'/paper/ocr',b,'POST',retryBody,randomUUID());check(result,202);check(await worker(),200);assert.equal((await call('/wat/sessions/'+other+'/paper/ocr',b)).body.data.ocr_revision,1);
   assert.equal((await service('wat_sessions?user_id=eq.'+b.id+'&is_free_demo=eq.true&select=id')).length,1);
  });
  await t.test('confirmation survives Storage outage and cleanup retries deletion',async()=>{
   execFileSync('docker',['stop','--timeout','2','supabase_storage_qiyadat-local'],{stdio:'ignore',timeout:30000});storageStopped=true;
   try{const result=await call('/wat/sessions/'+other+'/paper/confirm',b,'PUT',confirm(1,'PRIVATE-CONFIRMED: Corrected after review.'));check(result,200);assert.equal(result.body.data.images.status,'delete_pending');}
   finally{execFileSync('docker',['start','supabase_storage_qiyadat-local'],{stdio:'ignore',timeout:30000});storageStopped=false;await storageReady();}
   check(await worker('paper-cleanup'),200);const rows=await service('paper_uploads?session_id=eq.'+other+'&select=status');assert.ok(rows.every((row:any)=>row.status==='deleted'));
  });
  await t.test('Storage outage during upload recovers on the same canonical free demo',async()=>{
   const user=await actor(),id=await start(user),first=await prepare(user,id,['image/png']);
   execFileSync('docker',['stop','--timeout','2','supabase_storage_qiyadat-local'],{stdio:'ignore',timeout:30000});storageStopped=true;
   try{check(await upload(first[0].upload_url,user,'image/png',imageBytes()),503,'PROVIDER_UNAVAILABLE');}
   finally{execFileSync('docker',['start','supabase_storage_qiyadat-local'],{stdio:'ignore',timeout:30000});storageStopped=false;await storageReady();}
   const me=await call('/me',user);assert.equal(me.body.data.free_demo.can_retry_technical_failure,true);
   const retry=await prepare(user,id,['image/png']);assert.notEqual(retry[0].upload_id,first[0].upload_id);check(await upload(retry[0].upload_url,user,'image/png',imageBytes()),204);
   const demo=await service('wat_sessions?user_id=eq.'+user.id+'&is_free_demo=eq.true&select=id');assert.equal(demo.length,1);assert.equal(demo[0].id,id);
  });
  await t.test('all four private pages upload, rerun increments revision, and 280 Unicode code points confirm',async()=>{
   const id=await start(c),types=['image/png','image/jpeg','image/webp','image/png'] as const,four=await prepare(c,id,[...types]);assert.equal(four.length,4);
   for(let i=0;i<4;i++){const result=await upload(four[i].upload_url,c,types[i],imageBytes(types[i]));check(result,204);assert.equal(result.headers.get('cache-control'),'private, no-store');assert.ok(result.headers.get('x-request-id'));}
   const request={upload_ids:four.map(u=>u.upload_id),language:'en'};
   check(await call('/wat/sessions/'+id+'/paper/ocr',c,'POST',request,randomUUID()),202);check(await worker(),200);
   check(await call('/wat/sessions/'+id+'/paper/ocr',c,'POST',request,randomUUID()),202);check(await worker(),200);
   const draft=await call('/wat/sessions/'+id+'/paper/ocr',c);assert.equal(draft.body.data.ocr_revision,2);assert.equal(draft.body.data.responses.length,20);
   check(await call('/wat/sessions/'+id+'/paper/confirm',c,'PUT',confirm(1)),409,'OCR_CONFIRMATION_STALE');
   check(await call('/wat/sessions/'+id+'/paper/confirm',c,'PUT',confirm(2,'x'.repeat(281))),422,'VALIDATION_ERROR');
   const answer='e\u0301'.repeat(279)+'\u{1f600}';check(await call('/wat/sessions/'+id+'/paper/confirm',c,'PUT',confirm(2,answer)),200);
   const saved=(await service('wat_responses?session_id=eq.'+id+'&position=eq.1&select=answer'))[0].answer;assert.equal([...saved].length,280);assert.equal(saved,answer.normalize('NFC'));
  });
  await t.test('correct checksum does not make invalid image magic acceptable',async()=>{
   const id=await start(c),bytes=imageBytes().slice(0,8),file=await metadata('image/png',1,bytes);
   const result=await call('/wat/sessions/'+id+'/paper/uploads',c,'POST',{files:[file]});check(result,201);const u=result.body.data.uploads[0];secrets.push(u.upload_url,new URL(u.upload_url).searchParams.get('token')!);
   const row=(await service('paper_uploads?session_id=eq.'+id+'&select=object_path'))[0];paths.push(row.object_path);secrets.push(row.object_path);
   check(await upload(u.upload_url,c,'image/png',bytes),415,'UNSUPPORTED_MEDIA_TYPE');const r=await stored(row.object_path);assert.ok(!r.ok);await r.body?.cancel();
  });
  await t.test('missing private object is rejected before quota and permits trusted recapture',async()=>{
   const id=await start(c),first=await prepare(c,id,['image/png']);check(await upload(first[0].upload_url,c,'image/png',imageBytes()),204);
   const row=(await service('paper_uploads?session_id=eq.'+id+'&select=object_path'))[0];
   const removed=await request('/storage/v1/object/paper-uploads',{method:'DELETE',headers:serviceHeaders,body:JSON.stringify({prefixes:[row.object_path]})});assert.ok(removed.ok);await removed.body?.cancel();
   check(await call('/wat/sessions/'+id+'/paper/ocr',c,'POST',{upload_ids:[first[0].upload_id],language:'en'},randomUUID()),422,'PAPER_UPLOAD_INCOMPLETE');
   assert.equal((await service('usage_reservations?session_id=eq.'+id+'&select=id')).length,0);
   const retry=await prepare(c,id,['image/png']);assert.notEqual(retry[0].upload_id,first[0].upload_id);check(await upload(retry[0].upload_url,c,'image/png',imageBytes()),204);
  });
  await t.test('expired upload capabilities fail before Storage, even with authenticated ownership',async()=>{
   const id=await start(c),uploadId=randomUUID(),path=`paper-pages/${c.id}/${id}/${uploadId}.png`,now=Date.now(),file=await metadata('image/png');paths.push(path);secrets.push(path);
   await service('paper_uploads','POST',{id:uploadId,user_id:c.id,session_id:id,page_number:1,content_type:file.content_type,size_bytes:file.size_bytes,sha256:file.sha256,object_path:path,
    created_at:new Date(now-3600000).toISOString(),upload_expires_at:new Date(now-2700000).toISOString(),expires_at:new Date(now+23*3600000).toISOString()});
   check(await upload(api+`/wat/sessions/${id}/paper/uploads/${uploadId}/content?token=`+'0'.repeat(64),c,'image/png',imageBytes()),410,'UPLOAD_EXPIRED');
   check(await worker('paper-cleanup'),200);assert.equal((await service('paper_uploads?id=eq.'+uploadId+'&select=status'))[0].status,'deleted');
  });
  await t.test('cleanup removes only an exact controlled orphan object and safely repeats',async()=>{
   const id=randomUUID(),uploadId=randomUUID(),path=`paper-pages/${c.id}/${id}/${uploadId}.png`;paths.push(path);secrets.push(path);
   const put=await request('/storage/v1/object/paper-uploads/'+path,{method:'POST',headers:{...serviceHeaders,'Content-Type':'image/png'},body:imageBytes()});assert.ok(put.ok);await put.body?.cancel();
   assert.match(path,/^paper-pages\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.png$/);
   execFileSync('docker',['exec','-i','supabase_db_qiyadat-local','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],{
    input:`update storage.objects set created_at=statement_timestamp()-interval '20 minutes' where bucket_id='paper-uploads' and name='${path}';`,stdio:['pipe','ignore','ignore'],timeout:30000});
   check(await worker('paper-cleanup'),200);const r=await stored(path);assert.ok(!r.ok);await r.body?.cancel();check(await worker('paper-cleanup'),200);
  });
  await t.test('expired prepared uploads and abandoned images are removed without deleting canonical text',async()=>{
   const id=await start(c),uploadId=randomUUID(),path=`paper-pages/${c.id}/${id}/${uploadId}.png`,now=Date.now(),created=new Date(now-25*3600000).toISOString();paths.push(path);secrets.push(path);
   const storedImage=await request('/storage/v1/object/paper-uploads/'+path,{method:'POST',headers:{...serviceHeaders,'Content-Type':'image/png'},body:imageBytes()});assert.ok(storedImage.ok);await storedImage.body?.cancel();
   const file=await metadata('image/png');await service('paper_uploads','POST',{id:uploadId,user_id:c.id,session_id:id,page_number:1,content_type:file.content_type,size_bytes:file.size_bytes,sha256:file.sha256,object_path:path,
    status:'uploaded',created_at:created,upload_expires_at:new Date(now-25*3600000+900000).toISOString(),expires_at:new Date(now-3600000).toISOString(),uploaded_at:new Date(now-25*3600000+1000).toISOString()});
   check(await call('/wat/sessions/'+id+'/paper/ocr',c,'POST',{upload_ids:[uploadId],language:'en'},randomUUID()),410,'UPLOAD_EXPIRED');
   check(await worker('paper-cleanup'),200);const r=await stored(path);assert.ok(!r.ok);await r.body?.cancel();assert.equal((await service('wat_responses?session_id=eq.'+session+'&position=eq.1&select=answer'))[0].answer,confirm(1).responses[0].confirmed_text);
  });
  await t.test('cleanup is repeatable and saved paper report remains readable with OCR disabled',async()=>{check(await worker('paper-cleanup'),200);await setting('ocr_enabled',false);check(await worker(),503,'FEATURE_DISABLED');check(await call('/wat/sessions/'+session+'/report',a),200);});
 }finally{
  if(storageStopped){execFileSync('docker',['start','supabase_storage_qiyadat-local'],{stdio:'ignore',timeout:30000});await storageReady();}
  for(const path of paths){const r=await request('/storage/v1/object/paper-uploads',{method:'DELETE',headers:serviceHeaders,body:JSON.stringify({prefixes:[path]})});await r.body?.cancel();}
  for(const [name,value] of settings)await service('app_settings?key=eq.'+name,'PATCH',{value});
  for(const id of users){await service('feedback_items?user_id=eq.'+id,'DELETE');await service('feedback_reports?user_id=eq.'+id,'DELETE');const r=await request('/auth/v1/admin/users/'+id,{method:'DELETE',headers:serviceHeaders});assert.ok(r.ok,'Synthetic account removed');await r.body?.cancel();}
  await writeFile(process.env.QIYADAT_PRIVACY_SENTINELS!,JSON.stringify(secrets),{mode:0o600});
 }
});
