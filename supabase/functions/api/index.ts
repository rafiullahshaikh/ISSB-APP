import {createApp} from '../_shared/router.ts';
import {readEnvironment} from '../_shared/env.ts';

Deno.serve(createApp(readEnvironment()));
