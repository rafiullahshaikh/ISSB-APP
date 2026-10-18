import {spawn,execFileSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {localCli,localStatus} from './local_supabase_cli.ts';
function sql(statement:string){
 try{return execFileSync('docker',['exec','-i','supabase_db_qiyadat-local','psql','-U','postgres','-d','postgres','-X','-qAt','-v','ON_ERROR_STOP=1'],
  {input:statement,encoding:'utf8',stdio:['pipe','pipe','pipe'],timeout:60000}).trim();}
 catch{throw new Error('Local progress clock operation failed; no database diagnostics are printed.');}
}
try{execFileSync('docker',['image','inspect','public.ecr.aws/supabase/edge-runtime:v1.77.1'],{stdio:'ignore',timeout:30000});}
catch{throw new Error('The cached Edge Runtime is unavailable; obtain approval before downloading it.');}
const local=localStatus(),original=sql("select pg_get_functiondef('private.progress_clock()'::regprocedure);"),marker=randomUUID();
if(!original.includes('statement_timestamp()'))throw new Error('Progress clock was not in its normal production state. Restore it before testing.');
let serve:ReturnType<typeof spawn>|undefined,output='';
const secrets=[local.SERVICE_ROLE_KEY,local.ANON_KEY,'PRIVATE-PROGRESS-',marker];
try{
 sql("create or replace function private.progress_clock() returns timestamptz language sql stable security invoker set search_path = '' as $$select '2026-03-10T10:00:00Z'::timestamptz$$;");
 serve=spawn(localCli,['functions','serve','api','--no-verify-jwt'],{stdio:['ignore','pipe','pipe']});
 serve.stdout!.on('data',chunk=>{output+=chunk;});serve.stderr!.on('data',chunk=>{output+=chunk;});
 let ready=false,stable=0;
 for(let attempt=0;attempt<300;attempt++){
  if(serve.exitCode!==null)throw new Error('Local API server exited before startup.');
  try{const health=await fetch(local.API_URL+'/functions/v1/api/v1/health',{signal:AbortSignal.timeout(1500)});
   const progress=await fetch(local.API_URL+'/functions/v1/api/v1/progress',{signal:AbortSignal.timeout(1500)});
   if(health.ok&&progress.status===401){if(++stable>=2){ready=true;break;}}else stable=0;
   await health.body?.cancel();await progress.body?.cancel();
  }catch{stable=0;}await new Promise(resolve=>setTimeout(resolve,1000));
 }
 if(!ready)throw new Error('Local progress route did not become ready.');
 console.log('Local progress API is ready with a fixed private test clock; no provider is configured.');
 const child=spawn(process.execPath,['--experimental-strip-types','--test-isolation=none','--test','supabase/functions/tests/progress_http_test.ts'],
  {stdio:['ignore','inherit','inherit','ipc'],env:{...process.env,QIYADAT_PROGRESS_TEST_MARKER:marker}});
 child.on('message',(message:any)=>{if(message?.type==='privacy'&&Array.isArray(message.values))for(const value of message.values)if(typeof value==='string'&&value.length>5)secrets.push(value);});
 process.exitCode=await new Promise<number>((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>resolve(code??1));});
 if(secrets.some(value=>output.includes(value))||/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/.test(output))throw new Error('Sensitive fixture appeared in application runtime logs.');
 console.log('PASS: progress runtime logs contain no private fixture data, bearer tokens or keys.');
}finally{
 if(serve){serve.kill('SIGINT');await new Promise<void>(resolve=>{if(serve!.exitCode!==null)resolve();else{serve!.once('exit',()=>resolve());setTimeout(()=>{serve!.kill();resolve();},5000).unref();}});}
 sql(original);
 if(sql("select pg_get_functiondef('private.progress_clock()'::regprocedure);")!==original)throw new Error('Progress clock restoration failed.');
 console.log('PASS: the private progress clock is restored to statement_timestamp.');
}
