import test from 'node:test';
import assert from 'node:assert/strict';
import {assertImagePath,boundedBytes,validateFormat,validateImage,MAX_IMAGE,safePath} from '../_shared/paper/images.ts';
import {PaperStorage} from '../_shared/paper/storage.ts';
import {paperMutation} from '../_shared/paper/api.ts';
import {ApiError} from '../_shared/errors.ts';
import {imageBytes,imageRecord} from './paper_fixtures.ts';
for(const mime of ['image/png','image/jpeg','image/webp'] as const){
 test('actual '+mime+' fixture passes container, size and checksum validation',async()=>validateImage(await imageRecord(mime),imageBytes(mime)));
 test(mime+' trailing polyglot data is rejected',()=>{const bytes=imageBytes(mime),extra=new Uint8Array(bytes.length+8);extra.set(bytes);extra.set(new TextEncoder().encode('<script>'),bytes.length);assert.throws(()=>validateFormat(extra,mime),ApiError);});
}
test('MIME spoof, invalid magic and corrupt PNG chunk CRC fail closed',()=>{assert.throws(()=>validateFormat(imageBytes('image/jpeg'),'image/png'),ApiError);assert.throws(()=>validateFormat(new Uint8Array([1,2,3]),'image/jpeg'),ApiError);const bytes=imageBytes();bytes[40]^=1;assert.throws(()=>validateFormat(bytes,'image/png'),ApiError);});
test('size and checksum mismatches are rejected',async()=>{const image=await imageRecord();await assert.rejects(validateImage({...image,size_bytes:image.size_bytes+1},imageBytes()),e=>e instanceof ApiError&&e.code==='PAPER_UPLOAD_INCOMPLETE');await assert.rejects(validateImage({...image,sha256:'0'.repeat(64)},imageBytes()),ApiError);await assert.rejects(validateImage({...image,size_bytes:MAX_IMAGE+1},imageBytes()),e=>e instanceof ApiError&&e.code==='UPLOAD_TOO_LARGE');});
test('expired uploads and foreign fixed-path records fail',async()=>{const image=await imageRecord();await assert.rejects(validateImage({...image,expires_at:new Date(0).toISOString()},imageBytes()),e=>e instanceof ApiError&&e.code==='UPLOAD_EXPIRED');assert.throws(()=>assertImagePath({...image,user_id:crypto.randomUUID()}),ApiError);});
test('safe Storage path rejects traversal, broad prefix and wrong bucket',async()=>{assert.equal(safePath('../paper-pages'),false);assert.equal(safePath('paper-pages/'),false);const image=await imageRecord();assert.throws(()=>assertImagePath({...image,bucket_id:'public'}),ApiError);});
test('bounded streaming rejects oversized and stalled bodies',async()=>{await assert.rejects(boundedBytes(new Response(new Uint8Array(20)).body,10),e=>e instanceof ApiError&&e.code==='UPLOAD_TOO_LARGE');await assert.rejects(boundedBytes(new ReadableStream({pull:()=>new Promise(()=>{})}),10,20),e=>e instanceof ApiError&&e.code==='PROVIDER_UNAVAILABLE');});
test('Storage server calls never copy user credentials and delete only an exact private key',async()=>{
 const calls:any[]=[],image=await imageRecord(),env={url:'http://local',serviceKey:'synthetic-secret',publishableKey:'public',origins:new Set<string>(),release:'test'};
 const storage=new PaperStorage(env,async(url,init)=>{calls.push({url,init});return new Response('{}',{status:200});});
 await storage.upload(image,imageBytes());await storage.remove(image.object_path);assert.equal(new Headers(calls[0].init.headers).get('apikey'),'synthetic-secret');
 assert.deepEqual(JSON.parse(calls[1].init.body),{prefixes:[image.object_path]});await assert.rejects(storage.remove('paper-pages/'),ApiError);await assert.rejects(storage.remove(image.object_path,'public'),ApiError);
});
test('missing private bytes are rejected before quota and recorded as a trusted recoverable failure',async()=>{
 const image=await imageRecord(),calls:any[]=[],env={url:'http://local',serviceKey:'synthetic-secret',publishableKey:'public',origins:new Set<string>(),release:'test'};
 const service={rpc:async(name:string,body:any)=>{calls.push({name,body});return name==='qiyadat_paper_ocr_context'?{uploads:[image]}:true;}} as any;
 await assert.rejects(paperMutation('paper_ocr',image.session_id,{upload_ids:[image.id],language:'en'},'synthetic-idempotency-key',
  {id:image.user_id} as any,service,env,async()=>Response.json({error:'not_found'},{status:400})),e=>e instanceof ApiError&&e.code==='PAPER_UPLOAD_INCOMPLETE');
 assert.deepEqual(calls.map(c=>c.name),['qiyadat_paper_ocr_context','qiyadat_paper_storage_failure']);assert.equal(calls[1].body.p_upload,image.id);
});
