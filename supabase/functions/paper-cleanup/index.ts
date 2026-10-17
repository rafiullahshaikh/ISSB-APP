import {readEnvironment} from '../_shared/env.ts';
import {createPaperWorker} from '../_shared/paper/worker.ts';
const handler=createPaperWorker(readEnvironment(),Deno.env.get('QIYADAT_WORKER_SECRET')||'',{cleanup:true});
Deno.serve(request=>handler(request));
