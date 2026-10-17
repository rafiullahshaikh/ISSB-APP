import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {existsSync} from 'node:fs';
// Use the installed executable directly on Windows; no package installation or
// runtime download is performed. The npm launcher can stall during cold startup.
export const localCli=join(process.env.USERPROFILE!,'node_modules','@supabase','cli-windows-'+process.arch,'bin','supabase.exe');
export function localStatus(){
 if(process.platform!=='win32'||!existsSync(localCli))throw new Error('The installed local Windows Supabase CLI is unavailable.');
 let status:any;
 try{status=JSON.parse(execFileSync(process.execPath,[join(process.env.USERPROFILE!,'node_modules','supabase','dist','supabase.js'),'status','-o','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:60000}));}
 catch{throw new Error('Local Supabase status is unavailable. Start the local stack first.');}
 if(status.API_URL!=='http://127.0.0.1:55321'||!status.ANON_KEY||!status.SERVICE_ROLE_KEY)throw new Error('Only the Qiyadat local stack is allowed.');
 return status;
}
