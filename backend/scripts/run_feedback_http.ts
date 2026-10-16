import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,sep} from 'node:path';
import {randomUUID} from 'node:crypto';
import {startMockServer} from './feedback_mock_server.ts';
import {localCli,localStatus} from './local_supabase_cli.ts';
localStatus();
const mock=await startMockServer(),directory=await mkdtemp(join(tmpdir(),'qiyadat-feedback-'));
const workerSecret=randomUUID()+randomUUID(),envPath=join(directory,'worker.env');
await writeFile(envPath,[`GEMINI_API_KEY=${mock.apiKey}`,'GEMINI_MODEL=synthetic-model','GEMINI_PROMPT_VERSION=synthetic-prompt-v1',
 'GEMINI_REQUEST_TIMEOUT_MS=10000',`QIYADAT_WORKER_SECRET=${workerSecret}`,'QIYADAT_LOCAL_TESTS=true',
 `QIYADAT_GEMINI_TEST_URL=http://host.docker.internal:${mock.port}`].join('\n'),{mode:0o600});
const serve=spawn(localCli,['functions','serve','--no-verify-jwt','--env-file',envPath],{stdio:['ignore','pipe','pipe']});
let output='';serve.stdout.on('data',chunk=>{output+=chunk;});serve.stderr.on('data',chunk=>{output+=chunk;});
try{
 let ready=false,stable=0;
 for(let attempt=0;attempt<300;attempt++){
  if(serve.exitCode!==null)throw new Error('Local function server exited before startup.');
  try{const result=await fetch('http://127.0.0.1:55321/functions/v1/api/v1/health',{signal:AbortSignal.timeout(1500)});
   const configuration=await fetch('http://127.0.0.1:55321/functions/v1/api/v1/config/wat?kind=diagnostic',{signal:AbortSignal.timeout(1500)});
   const worker=await fetch('http://127.0.0.1:55321/functions/v1/feedback-worker',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+workerSecret},body:'{"unexpected":true}',signal:AbortSignal.timeout(1500)});
   if(result.ok&&configuration.ok&&worker.status===422){if(++stable>=2){ready=true;break;}}else stable=0;
   await result.body?.cancel();await configuration.body?.cancel();await worker.body?.cancel();
  }catch{stable=0;}
  await new Promise(resolve=>setTimeout(resolve,1000));
 }
 if(!ready)throw new Error('Local API/worker did not become ready.');
 console.log('Local API configuration and current synthetic worker are ready.');
 const test=spawn(process.execPath,['--experimental-strip-types','--test-isolation=none','--test','supabase/functions/tests/feedback_http_test.ts'],{
  stdio:'inherit',env:{...process.env,QIYADAT_TEST_WORKER_SECRET:workerSecret,QIYADAT_TEST_MOCK_CONTROL:mock.control,QIYADAT_TEST_MOCK_PORT:String(mock.port)}});
 const code=await new Promise<number>(resolve=>test.once('exit',value=>resolve(value??1)));process.exitCode=code;
 if(/PRIVATE-ANSWER|qiyadat-phase3-.*@example\.invalid/.test(output))throw new Error('Sensitive fixture appeared in function logs.');
 console.log('PASS: worker/API runtime logs contain no sensitive fixture content.');
}finally{
 serve.kill('SIGINT');await new Promise<void>(resolve=>{if(serve.exitCode!==null)resolve();else{serve.once('exit',()=>resolve());setTimeout(()=>{serve.kill();resolve();},5000).unref();}});
 mock.server.closeAllConnections();await new Promise<void>(resolve=>mock.server.close(()=>resolve()));
 const target=resolve(directory),temporaryRoot=resolve(tmpdir())+sep;
 if(!target.startsWith(temporaryRoot)||!target.slice(temporaryRoot.length).startsWith('qiyadat-feedback-'))throw new Error('Unexpected temporary cleanup path.');
 await rm(target,{recursive:true,force:true});
}
