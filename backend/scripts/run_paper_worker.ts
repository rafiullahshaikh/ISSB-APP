import {setTimeout as delay} from 'node:timers/promises';
import {randomUUID} from 'node:crypto';
const secret=process.env.QIYADAT_WORKER_SECRET;
if(!secret||secret.length<32)throw new Error('Supply the same private worker secret used by the local Edge Runtime.');
const controller=new AbortController();process.once('SIGINT',()=>controller.abort());process.once('SIGTERM',()=>controller.abort());
console.log('Local OCR and paper cleanup polling every five seconds.');
while(!controller.signal.aborted){
 for(const name of ['ocr-worker','paper-cleanup']){
  if(controller.signal.aborted)break;
  const id='req_'+randomUUID().replaceAll('-','');
  try{const r=await fetch('http://127.0.0.1:55321/functions/v1/'+name,{method:'POST',headers:{Authorization:'Bearer '+secret,'Content-Type':'application/json','X-Request-Id':id},body:'{}',
   signal:AbortSignal.any([controller.signal,AbortSignal.timeout(240000)])});await r.body?.cancel();if(!r.ok)console.log(JSON.stringify({request_id:id,route:name,status:r.status,code:'WORKER_REQUEST_FAILED'}));
  }catch{if(!controller.signal.aborted)console.log(JSON.stringify({request_id:id,route:name,code:'PROVIDER_UNAVAILABLE'}));}
 }
 try{await delay(5000,undefined,{signal:controller.signal});}catch{break;}
}
