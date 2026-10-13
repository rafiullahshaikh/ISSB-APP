export interface Environment {url:string; publishableKey:string; serviceKey:string; origins:Set<string>; release:string}
export function readEnvironment(get:(name:string)=>string|undefined = name => {
 const globals=globalThis as any; return globals.Deno?.env.get(name) ?? globals.process?.env[name];
}):Environment {
 const url=get('SUPABASE_URL');
 const publishableKey=get('SUPABASE_PUBLISHABLE_KEY') || get('SUPABASE_ANON_KEY');
 const serviceKey=get('SUPABASE_SECRET_KEY') || get('SUPABASE_SERVICE_ROLE_KEY');
 if(!url || !publishableKey || !serviceKey) throw new Error('Required API environment is unavailable.');
 const parsed=new URL(url); if(!['http:','https:'].includes(parsed.protocol)) throw new Error('Invalid API environment.');
 const origins=new Set((get('QIYADAT_ALLOWED_ORIGINS') ||
  'http://127.0.0.1:8080,http://localhost:8080,http://127.0.0.1:8765,http://localhost:8765').split(',').map(v=>v.trim()).filter(Boolean));
 for(const origin of origins) {const value=new URL(origin); if(value.origin!==origin || !['http:','https:'].includes(value.protocol)) throw new Error('Invalid CORS configuration.');}
 const release=get('QIYADAT_RELEASE') || '2026.10.0';
 if(!/^[a-zA-Z0-9._-]{1,40}$/.test(release)) throw new Error('Invalid release configuration.');
 return {url:parsed.origin,publishableKey,serviceKey,origins,release};
}
