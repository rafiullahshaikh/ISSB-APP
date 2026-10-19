import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:net';
import {randomBytes,randomUUID} from 'node:crypto';
import {localCli,localStatus} from './local_supabase_cli.ts';
const local=localStatus(),key=randomBytes(32).toString('base64'),pipe='\\\\.\\pipe\\qiyadat-payments-'+randomUUID();
try{execFileSync('docker',['image','inspect','public.ecr.aws/supabase/edge-runtime:v1.77.1'],{stdio:'ignore',timeout:30000});}
catch{throw new Error('Cached Edge Runtime unavailable; no download was attempted.');}
// The CLI reads dotenv from a Windows named pipe. Synthetic encryption key never
// exists in a filesystem file, shell argument, test output, or repository.
const channel=createServer(socket=>socket.end('PAYMENT_TRANSACTION_ENCRYPTION_KEY='+key+'\n'));
await new Promise<void>((resolve,reject)=>{channel.once('error',reject);channel.listen(pipe,resolve);});
let serve:ReturnType<typeof spawn>|undefined,output='';
const privateValues=[key,local.ANON_KEY,local.SERVICE_ROLE_KEY];
try{
 serve=spawn(localCli,['functions','serve','api','--no-verify-jwt','--env-file',pipe],{stdio:['ignore','pipe','pipe']});
 serve.stdout!.on('data',c=>{output+=c;});serve.stderr!.on('data',c=>{output+=c;});
 let ready=false;
 for(let i=0;i<180;i++){
  if(serve.exitCode!==null)throw new Error('Local payment API startup failed; private runtime output withheld.');
  try{const r=await fetch(local.API_URL+'/functions/v1/api/v1/payment-offers',{signal:AbortSignal.timeout(2000)});const body=await r.json();if(r.status===503&&body.error?.code==='FEATURE_DISABLED'){ready=true;break;}}catch{}
  await new Promise(r=>setTimeout(r,1000));
 }
 if(!ready)throw new Error('Local payment API did not become ready.');
 console.log('Local payment API ready; encryption key exists only in memory.');
 const child=spawn(process.execPath,['--experimental-strip-types','--test-isolation=none','--test','supabase/functions/tests/payments_http_test.ts'],
  {stdio:['ignore','inherit','inherit','ipc'],env:{...process.env,QIYADAT_PAYMENT_TEST_KEY:key}});
 child.on('message',(m:any)=>{if(m?.type==='privacy'&&Array.isArray(m.values))for(const s of m.values)if(typeof s==='string'&&s.length>5)privateValues.push(s);});
 process.exitCode=await new Promise<number>((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>resolve(code??1));});
 if(privateValues.some(s=>output.includes(s))||/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/.test(output))throw new Error('Private payment fixture found in application logs.');
 console.log('PASS: payment runtime logs contain no references, emails, notes, hashes, ciphertext, tokens or keys.');
}finally{
 if(serve){serve.kill('SIGINT');await new Promise<void>(resolve=>{if(serve!.exitCode!==null)resolve();else{serve!.once('exit',()=>resolve());setTimeout(()=>{serve!.kill();resolve();},5000).unref();}});}
 await new Promise<void>(resolve=>channel.close(()=>resolve()));
}
