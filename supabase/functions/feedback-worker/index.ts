import {readEnvironment} from '../_shared/env.ts';
import {readGeminiEnvironment} from '../_shared/feedback/gemini.ts';
import {createWorker} from '../_shared/feedback/worker.ts';
import {failure,requestId} from '../_shared/http.ts';
import {normalizeError} from '../_shared/errors.ts';
// Missing provider configuration disables this worker without disabling the API.
let handler:(request:Request)=>Promise<Response>;
try{handler=createWorker(readEnvironment(),readGeminiEnvironment(name=>Deno.env.get(name)));}
catch(error){handler=async request=>failure(normalizeError(error),requestId(request.headers.get('x-request-id')),new Headers());}
Deno.serve(request=>handler(request));
