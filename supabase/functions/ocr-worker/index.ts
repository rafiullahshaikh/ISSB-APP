import {readEnvironment} from '../_shared/env.ts';
import {readVisionEnvironment} from '../_shared/paper/vision.ts';
import {createPaperWorker} from '../_shared/paper/worker.ts';
const get=(name:string)=>Deno.env.get(name),env=readEnvironment(get);
let config;try{config=readVisionEnvironment(get);}catch{}
const handler=createPaperWorker(env,get('QIYADAT_WORKER_SECRET')||'',{config});
Deno.serve(request=>handler(request));
