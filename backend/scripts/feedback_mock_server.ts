import {createServer} from 'node:http';
import {randomUUID} from 'node:crypto';
import {validFeedback,providerEnvelope} from '../../supabase/functions/tests/feedback_fixtures.ts';
export async function startMockServer(){
 let mode='valid',calls=0;const control=randomUUID(),apiKey='synthetic-local-gemini-key';
 const server=createServer(async(req,res)=>{
  res.setHeader('Content-Type','application/json');
  if(req.method!=='POST'){res.writeHead(405).end('{}');return;}
  let raw='';for await(const chunk of req){raw+=chunk;if(raw.length>131072){res.writeHead(413).end('{}');return;}}
  let body:any;try{body=JSON.parse(raw);}catch{res.writeHead(400).end('{}');return;}
  if(req.url==='/control'){
   if(req.headers['x-mock-control']!==control){res.writeHead(403).end('{}');return;}
   if(['valid','invalid','unavailable','invalid-once','refusal'].includes(body.mode))mode=body.mode;
   res.end(JSON.stringify({mode,calls}));return;
  }
  if(req.headers['x-goog-api-key']!==apiKey||!/^\/v1beta\/models\/synthetic-model:generateContent$/.test(req.url||'')){res.writeHead(403).end('{}');return;}
  calls++;
  if(mode==='unavailable'){res.writeHead(503).end('{}');return;}
  if(mode==='refusal'){res.end(JSON.stringify({promptFeedback:{blockReason:'SAFETY'}}));return;}
  let input:any;try{input=JSON.parse(body.contents[0].parts[0].text);
   if(!Array.isArray(input)||input.length!==20||input.some((r:any)=>Object.keys(r).sort().join(',')!=='answer,position,word'))throw new Error();
  }catch{res.writeHead(400).end('{}');return;}
  if(mode==='invalid'||mode==='invalid-once'){if(mode==='invalid-once')mode='valid';res.end(JSON.stringify({modelVersion:'synthetic-model-v1',candidates:[{finishReason:'STOP',content:{parts:[{text:'{}'}]}}]}));return;}
  res.end(JSON.stringify(providerEnvelope(validFeedback(input.map((r:any)=>({...r,status:r.answer.trim()?'answered':'blank'}))))));
 });
 await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(0,'0.0.0.0',()=>resolve());});
 const port=(server.address() as any).port;
 return {server,port,control,apiKey};
}
if(process.argv[1]?.endsWith('feedback_mock_server.ts')){
 const mock=await startMockServer();console.log('Local synthetic Gemini mock listening on port '+mock.port+'. Use the HTTP test runner for automatic worker configuration.');
}
