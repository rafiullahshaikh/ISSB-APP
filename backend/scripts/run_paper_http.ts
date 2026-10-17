import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,sep} from 'node:path';
import {randomUUID} from 'node:crypto';
import {startMockServer} from './feedback_mock_server.ts';
import {startVisionMock} from './paper_mock_server.ts';
import {localCli,localStatus} from './local_supabase_cli.ts';
// Refuse an implicit runtime download; the verified local image must exist.
try{execFileSync('docker',['image','inspect','public.ecr.aws/supabase/edge-runtime:v1.77.1'],{stdio:'ignore',timeout:30000});}
catch{throw new Error('The cached Edge Runtime is unavailable; obtain approval before downloading it.');}
const local=localStatus(),gemini=await startMockServer(),vision=await startVisionMock();
const directory=await mkdtemp(join(tmpdir(),'qiyadat-paper-')),envPath=join(directory,'worker.env'),sentinels=join(directory,'privacy.json'),secret=randomUUID()+randomUUID();
await writeFile(envPath,[`GEMINI_API_KEY=${gemini.apiKey}`,'GEMINI_MODEL=synthetic-model','GEMINI_PROMPT_VERSION=synthetic-prompt-v1','GEMINI_REQUEST_TIMEOUT_MS=10000',
 `QIYADAT_WORKER_SECRET=${secret}`,'QIYADAT_LOCAL_TESTS=true',`QIYADAT_GEMINI_TEST_URL=http://host.docker.internal:${gemini.port}`,
 'OCR_PROVIDER=google_cloud_vision','GOOGLE_CLOUD_PROJECT_ID=synthetic-project','GOOGLE_CLOUD_VISION_TIMEOUT_MS=10000',
 `GOOGLE_CLOUD_VISION_ENDPOINT=http://host.docker.internal:${vision.port}`,`GOOGLE_CLOUD_VISION_CREDENTIALS_JSON=${JSON.stringify({type:'local_mock',access_token:vision.token})}`].join('\n'),{mode:0o600});
await writeFile(sentinels,'[]',{mode:0o600});
const serve=spawn(localCli,['functions','serve','--no-verify-jwt','--env-file',envPath],{stdio:['ignore','pipe','pipe']});let output='';
serve.stdout.on('data',chunk=>{output+=chunk;});serve.stderr.on('data',chunk=>{output+=chunk;});
try{
 let stable=0,ready=false;
 for(let i=0;i<300;i++){
  if(serve.exitCode!==null)throw new Error('Local function server exited before startup.');
  try{const health=await fetch(local.API_URL+'/functions/v1/api/v1/health',{signal:AbortSignal.timeout(1500)});
   const worker=await fetch(local.API_URL+'/functions/v1/ocr-worker',{method:'POST',headers:{Authorization:'Bearer '+secret,'Content-Type':'application/json'},body:'{"unexpected":true}',signal:AbortSignal.timeout(1500)});
   if(health.ok&&worker.status===422){if(++stable>=2){ready=true;break;}}else stable=0;await health.body?.cancel();await worker.body?.cancel();
  }catch{stable=0;}await new Promise(resolve=>setTimeout(resolve,1000));
 }
 if(!ready)throw new Error('Local paper API/worker did not become ready.');console.log('Local protected upload/OCR functions and synthetic providers are ready.');
 const child=spawn(process.execPath,['--experimental-strip-types','--test-isolation=none','--test','supabase/functions/tests/paper_http_test.ts'],{stdio:'inherit',
  env:{...process.env,QIYADAT_TEST_WORKER_SECRET:secret,QIYADAT_TEST_VISION_CONTROL:vision.control,QIYADAT_TEST_VISION_PORT:String(vision.port),QIYADAT_PRIVACY_SENTINELS:sentinels}});
 process.exitCode=await new Promise<number>(resolve=>child.once('exit',code=>resolve(code??1)));
 const privateValues=[secret,vision.token,gemini.apiKey,local.SERVICE_ROLE_KEY,'PRIVATE-OCR','PRIVATE-CONFIRMED',...JSON.parse(await readFile(sentinels,'utf8'))];
 if(privateValues.some(value=>typeof value==='string'&&value.length>5&&output.includes(value)))throw new Error('Sensitive fixture content appeared in application runtime logs.');
 console.log('PASS: API/worker runtime logs contain no images, OCR, confirmed text, capabilities, paths or credentials.');
}finally{
 serve.kill('SIGINT');await new Promise<void>(resolve=>{if(serve.exitCode!==null)resolve();else{serve.once('exit',()=>resolve());setTimeout(()=>{serve.kill();resolve();},5000).unref();}});
 for(const mock of [gemini,vision]){mock.server.closeAllConnections();await new Promise<void>(resolve=>mock.server.close(()=>resolve()));}
 const target=resolve(directory),root=resolve(tmpdir())+sep;if(!target.startsWith(root)||!target.slice(root.length).startsWith('qiyadat-paper-'))throw new Error('Unexpected temporary cleanup path.');
 await rm(target,{recursive:true,force:true});
}
