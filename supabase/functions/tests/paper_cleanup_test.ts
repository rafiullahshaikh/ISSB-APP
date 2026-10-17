import test from 'node:test';
import assert from 'node:assert/strict';
import {cleanupPaper,paperMutation} from '../_shared/paper/api.ts';
import {PaperStorage} from '../_shared/paper/storage.ts';
import {imageRecord} from './paper_fixtures.ts';
const env={url:'http://local',serviceKey:'synthetic-service',publishableKey:'synthetic-public',origins:new Set<string>(),release:'test'};
test('cleanup deletes an exact Storage object before marking metadata deleted',async()=>{
 const image=await imageRecord(),calls:string[]=[];const service={rpc:async(name:string)=>{calls.push(name);return name.endsWith('candidates')?[image]:true;}} as any;
 const storage={remove:async()=>{calls.push('storage_delete');}} as any;assert.deepEqual(await cleanupPaper(service,storage),{deleted:1,pending:0});assert.deepEqual(calls,['qiyadat_paper_cleanup_candidates','storage_delete','qiyadat_paper_deleted']);
});
test('failed deletion remains pending and is not marked deleted',async()=>{
 const image=await imageRecord(),calls:string[]=[];const service={rpc:async(name:string)=>{calls.push(name);return [image];}} as any;
 assert.deepEqual(await cleanupPaper(service,{remove:async()=>{throw new Error('PRIVATE-PATH');}} as any),{deleted:0,pending:1});assert.equal(calls.length,1);
});
test('cleanup refuses broad or foreign paths before making a Storage request',async()=>{
 let requests=0;const storage=new PaperStorage(env,async()=>{requests++;return Response.json({});});
 const service={rpc:async()=>[{id:null,bucket_id:'paper-uploads',object_path:'paper-pages/'}]} as any;
 assert.deepEqual(await cleanupPaper(service,storage),{deleted:0,pending:1});assert.equal(requests,0);
});
test('orphan cleanup needs no metadata update and safely repeats on an empty batch',async()=>{
 const image=await imageRecord();let batch=0;const service={rpc:async()=>batch++===0?[{...image,id:null}]:[]} as any,storage={remove:async()=>{}} as any;
 assert.equal((await cleanupPaper(service,storage)).deleted,1);assert.deepEqual(await cleanupPaper(service,storage),{deleted:0,pending:0});
});
test('confirmation remains successful when deletion service is unavailable',async()=>{
 const service={rpc:async(name:string)=>{if(name==='qiyadat_paper_confirm')return {session_id:'session',status:'finished',images:{status:'delete_pending',delete_pending:true}};throw new Error('PRIVATE-STORAGE');}} as any;
 const result=await paperMutation('paper_confirm','session',{},null,{id:'owner'} as any,service,env);assert.equal(result.status,200);assert.equal(result.body.data.images.delete_pending,true);
});
