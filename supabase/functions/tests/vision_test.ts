import test from 'node:test';
import assert from 'node:assert/strict';
import {readVisionEnvironment,VisionProvider,visionLines,VisionFailure} from '../_shared/paper/vision.ts';
import {imageBytes,visionPayload} from './paper_fixtures.ts';
const values:Record<string,string>={SUPABASE_URL:'http://kong',QIYADAT_LOCAL_TESTS:'true',GOOGLE_CLOUD_PROJECT_ID:'synthetic-project',
 GOOGLE_CLOUD_VISION_CREDENTIALS_JSON:'{"type":"local_mock","access_token":"synthetic-vision-token"}',GOOGLE_CLOUD_VISION_TIMEOUT_MS:'100',
 GOOGLE_CLOUD_VISION_ENDPOINT:'http://host.docker.internal:12345',OCR_PROVIDER:'google_cloud_vision',QIYADAT_WORKER_SECRET:'synthetic-worker-secret-with-32-characters'};
const config=()=>readVisionEnvironment(name=>values[name]);
test('Vision mock configuration is accepted only for a local Supabase and local target',()=>{assert.equal(config().localMock,true);
 assert.equal(readVisionEnvironment(name=>({...values,GOOGLE_CLOUD_VISION_ENDPOINT:values.GOOGLE_CLOUD_VISION_ENDPOINT+'/'})[name]).endpoint,values.GOOGLE_CLOUD_VISION_ENDPOINT);
 for(const changes of [{SUPABASE_URL:'https://hosted.supabase.co'},{QIYADAT_LOCAL_TESTS:'false'},{GOOGLE_CLOUD_VISION_ENDPOINT:'http://external.example.invalid'},
  {GOOGLE_CLOUD_VISION_TIMEOUT_MS:'30001'},{OCR_PROVIDER:'gemini'}])assert.throws(()=>readVisionEnvironment(name=>({...values,...changes})[name]));});
test('Vision sends bytes, English hints and document detection, never image URLs or user identity',async()=>{
 let accepted=0;const provider=new VisionProvider(config(),async(url,init)=>{assert.equal(url,'http://host.docker.internal:12345/v1/images:annotate');
  const body=JSON.parse(init!.body as string),headers=new Headers(init!.headers);assert.equal(headers.get('authorization'),'Bearer synthetic-vision-token');
  assert.deepEqual(body.requests[0].features,[{type:'DOCUMENT_TEXT_DETECTION'}]);assert.deepEqual(body.requests[0].imageContext,{languageHints:['en']});assert.deepEqual(Object.keys(body.requests[0].image),['content']);
  return Response.json(visionPayload());});
 const lines=await provider.recognize(imageBytes(),'synthetic-correlation',async()=>{accepted++;});assert.equal(accepted,1);assert.equal(lines.length,2);
});
test('blank Vision page is valid, not automatically confirmed',()=>assert.deepEqual(visionLines({responses:[{}]}),[]));
test('hierarchy uses symbols, break hints and confidence while ignoring rotated coordinates',()=>{
 const result=visionLines({responses:[{fullTextAnnotation:{text:'1. Text\n',pages:[{blocks:[{paragraphs:[{boundingBox:{vertices:[{x:100,y:0},{x:0,y:100}]},words:[{confidence:0.9,symbols:[{text:'1.'},{text:' ',property:{detectedBreak:{type:'UNKNOWN'}}},{text:'Text',property:{detectedBreak:{type:'LINE_BREAK'}}}]}]}]}]}]}}]});
 assert.deepEqual(result,[{text:'1. Text',confidence:0.9}]);
});
test('inconsistent hierarchy falls back to full text instead of losing lines',()=>{const result=visionLines({responses:[{fullTextAnnotation:{text:'1. Complete\n2. Preserved',pages:[]}}]});assert.equal(result.length,2);assert.equal(result[1].confidence,null);});
test('hierarchy extras missing from full text are preserved and flagged for review',()=>{
 const words=['1. Primary','2. Extra'].map(text=>({symbols:[{text,property:{detectedBreak:{type:'LINE_BREAK'}}}]}));
 const result=visionLines({responses:[{fullTextAnnotation:{text:'1. Primary',pages:[{blocks:[{paragraphs:[{words}]}]}]}}]});
 assert.deepEqual(result,[{text:'1. Primary',confidence:null},{text:'2. Extra',confidence:null}]);
});
for(const payload of [{},null,{responses:[]},{responses:[{fullTextAnnotation:{text:4}}]},{responses:[{fullTextAnnotation:{text:'x',pages:[{blocks:'invalid'}]}}]}])test('malformed provider response fails with a safe code',()=>assert.throws(()=>visionLines(payload),VisionFailure));
test('provider permanent invalid image is terminal',async()=>{const provider=new VisionProvider(config(),async()=>Response.json({responses:[{error:{code:3,message:'PRIVATE-PROVIDER'}}]}));await assert.rejects(provider.recognize(imageBytes(),'request',async()=>{}),e=>e instanceof VisionFailure&&!e.retryable&&e.code==='OCR_FAILED'&&!e.message.includes('PRIVATE'));});
test('transient, quota and timeout failures are classified without provider text',async()=>{
 for(const [status,code,retry] of [[503,'PROVIDER_UNAVAILABLE',true],[429,'GLOBAL_QUOTA_EXHAUSTED',false]] as const){const p=new VisionProvider(config(),async()=>new Response('PRIVATE-ERROR',{status}));await assert.rejects(p.recognize(imageBytes(),'request',async()=>{}),e=>e instanceof VisionFailure&&e.code===code&&e.retryable===retry);}
 const p=new VisionProvider(config(),async(_url,init)=>new Promise((_,reject)=>init!.signal!.addEventListener('abort',()=>reject(new Error('PRIVATE-TIMEOUT')))));
 await assert.rejects(p.recognize(imageBytes(),'request',async()=>{}),e=>e instanceof VisionFailure&&e.retryable);
});
test('service-account OAuth assertion is signed, scoped and cached without a real credential',async()=>{
 const pair=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
 const pem='-----BEGIN PRIVATE KEY-----\n'+Buffer.from(await crypto.subtle.exportKey('pkcs8',pair.privateKey)).toString('base64')+'\n-----END PRIVATE KEY-----';
 const credentials={type:'service_account',project_id:'synthetic-project',client_email:'synthetic@synthetic-project.iam.gserviceaccount.com',token_uri:'https://oauth2.googleapis.com/token',private_key:pem};
 const config=readVisionEnvironment(name=>({...values,GOOGLE_CLOUD_VISION_ENDPOINT:'https://vision.googleapis.com/',GOOGLE_CLOUD_VISION_CREDENTIALS_JSON:JSON.stringify(credentials)})[name]);
 let oauth=0,vision=0;const provider=new VisionProvider(config,async(url,init)=>{
  if(url==='https://oauth2.googleapis.com/token'){oauth++;const form=new URLSearchParams(init!.body as URLSearchParams),parts=form.get('assertion')!.split('.');
   assert.equal(form.get('grant_type'),'urn:ietf:params:oauth:grant-type:jwt-bearer');const claims=JSON.parse(Buffer.from(parts[1],'base64url').toString());
   assert.equal(claims.scope,'https://www.googleapis.com/auth/cloud-vision');assert.equal(claims.aud,'https://oauth2.googleapis.com/token');assert.equal(claims.exp-claims.iat,3600);
   assert.equal(await crypto.subtle.verify('RSASSA-PKCS1-v1_5',pair.publicKey,Buffer.from(parts[2],'base64url'),new TextEncoder().encode(parts[0]+'.'+parts[1])),true);
   return Response.json({access_token:'synthetic-oauth-token',token_type:'Bearer',expires_in:3600});
  }
  vision++;assert.equal(new Headers(init!.headers).get('authorization'),'Bearer synthetic-oauth-token');return Response.json(visionPayload());
 });
 await provider.recognize(imageBytes(),'request-one',async()=>{});await provider.recognize(imageBytes(),'request-two',async()=>{});assert.equal(oauth,1);assert.equal(vision,2);
});
