export interface LogEvent {request_id:string; route:string; method:string; status:number; duration_ms:number; code?:string}
// Construct an allowlisted record, rather than serializing a request, exception or context.
export function safeLog(event:LogEvent,sink:(line:string)=>void=console.log):void {
 sink(JSON.stringify({request_id:event.request_id,route:event.route,method:event.method,status:event.status,
  duration_ms:Math.max(0,Math.round(event.duration_ms)),...(event.code ? {code:event.code}: {})}));
}
