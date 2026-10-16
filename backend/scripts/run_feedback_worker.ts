import {setTimeout as delay} from 'node:timers/promises';
import {randomUUID} from 'node:crypto';
const secret=process.env.QIYADAT_WORKER_SECRET;
if(!secret||secret.length<32)throw new Error('Supply the same private QIYADAT_WORKER_SECRET used by the local Edge Runtime.');
const controller=new AbortController();
process.once('SIGINT',()=>controller.abort());process.once('SIGTERM',()=>controller.abort());
console.log('Local feedback worker polling every five seconds.');
while(!controller.signal.aborted){
 const requestId='req_'+randomUUID().replaceAll('-','');
 try{
  const response=await fetch('http://127.0.0.1:55321/functions/v1/feedback-worker',{
   method:'POST',headers:{Authorization:'Bearer '+secret,'Content-Type':'application/json','X-Request-Id':requestId},body:'{}',
   signal:AbortSignal.any([controller.signal,AbortSignal.timeout(150000)])});
  await response.body?.cancel();
  if(!response.ok)console.log(JSON.stringify({request_id:requestId,status:response.status,code:'WORKER_REQUEST_FAILED'}));
 }catch{if(!controller.signal.aborted)console.log(JSON.stringify({request_id:requestId,code:'PROVIDER_UNAVAILABLE'}));}
 try{await delay(5000,undefined,{signal:controller.signal});}catch{break;}
}
