import {createServer} from 'node:http';
import {randomUUID} from 'node:crypto';
export async function startVisionMock(){
 const control=randomUUID()+randomUUID(),token='synthetic-vision-'+randomUUID();let mode='valid',requests=0;
 const server=createServer(async(req,res)=>{try{
  let body='';for await(const chunk of req){body+=chunk;if(body.length>12000000){res.writeHead(413).end();return;}}
  if(req.url==='/control'&&req.method==='POST'&&req.headers['x-mock-control']===control){const input=JSON.parse(body);if(!['valid','unavailable','invalid','blank','malformed'].includes(input.mode)){res.writeHead(400).end();return;}
   mode=input.mode;res.writeHead(200,{'Content-Type':'application/json'}).end(JSON.stringify({requests}));return;}
  if(req.url!=='/v1/images:annotate'||req.method!=='POST'||req.headers.authorization!=='Bearer '+token){res.writeHead(403).end();return;}
  const input=JSON.parse(body),request=input.requests?.[0];
  if(input.requests.length!==1||request.features?.[0]?.type!=='DOCUMENT_TEXT_DETECTION'||request.imageContext?.languageHints?.join()!=='en'||
   typeof request.image?.content!=='string'||Object.keys(request.image).join()!=='content'){res.writeHead(400).end();return;}
  requests++;res.setHeader('Content-Type','application/json');
  if(mode==='unavailable'){res.writeHead(503).end('{"error":{"message":"PRIVATE-PROVIDER"}}');return;}
  if(mode==='malformed'){res.writeHead(200).end('{malformed');return;}
  if(mode==='invalid'){res.writeHead(200).end('{"responses":[{"error":{"code":3,"message":"PRIVATE-PROVIDER"}}]}');return;}
  const result=mode==='blank'?{responses:[{}]}:{responses:[{fullTextAnnotation:{text:Array.from({length:20},(_,i)=>`${i+1}. PRIVATE-OCR draft ${i+1}.`).join('\n')}}]};
  res.writeHead(200).end(JSON.stringify(result));
 }catch{res.writeHead(400).end('{"error":"INVALID_REQUEST"}');}});
 await new Promise<void>(resolve=>server.listen(0,'0.0.0.0',resolve));const port=(server.address() as any).port as number;
 return {server,port,control,token};
}
