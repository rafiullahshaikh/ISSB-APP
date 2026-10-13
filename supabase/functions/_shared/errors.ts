export const errorStatus: Record<string, number> = {
 INVALID_JSON:400, INVALID_REQUEST:400, VALIDATION_ERROR:422, AUTH_REQUIRED:401, AUTH_INVALID:401,
 REAUTH_REQUIRED:401, FORBIDDEN:403, ADMIN_REQUIRED:403, ENTITLEMENT_REQUIRED:403, DIAGNOSTIC_ALREADY_USED:403,
 NOT_FOUND:404, IDEMPOTENCY_CONFLICT:409, CONFIG_VERSION_MISMATCH:409, SESSION_STATE_CONFLICT:409,
 SESSION_ALREADY_FINISHED:409, SESSION_NOT_FINISHED:409, SESSION_LATE_ANSWER:409, ANSWER_NOT_ACTIVE:409,
 ANSWER_ALREADY_LOCKED:409, SESSION_EXPIRED:410, RATE_LIMITED:429, FEATURE_DISABLED:503,
 PROVIDER_UNAVAILABLE:503, INTERNAL_ERROR:500,
};
const messages: Record<string,string> = {
 INVALID_JSON:'The request body is not valid JSON.', INVALID_REQUEST:'The request is not supported.',
 VALIDATION_ERROR:'The request could not be validated.', AUTH_REQUIRED:'A user access token is required.',
 AUTH_INVALID:'The user session is invalid or expired.', NOT_FOUND:'The resource was not found.',
 FORBIDDEN:'Access is not permitted.', ADMIN_REQUIRED:'Administrator access is required.',
 ENTITLEMENT_REQUIRED:'Active beta or paid access is required.', DIAGNOSTIC_ALREADY_USED:'Your lifetime diagnostic demo has already been claimed.',
 IDEMPOTENCY_CONFLICT:'The idempotency key or client session ID was reused with different input.',
 CONFIG_VERSION_MISMATCH:'The WAT configuration is unknown or obsolete.', SESSION_STATE_CONFLICT:'This operation is unavailable in the current session state.',
 SESSION_ALREADY_FINISHED:'This session has already finished.', SESSION_EXPIRED:'This session no longer accepts writes.',
 ANSWER_NOT_ACTIVE:'This position has not opened yet.', SESSION_LATE_ANSWER:'This answer arrived after the permitted window.',
 ANSWER_ALREADY_LOCKED:'This answer is locked.', RATE_LIMITED:'Please wait before making another request.',
 FEATURE_DISABLED:'This feature is currently unavailable.', PROVIDER_UNAVAILABLE:'A required service is temporarily unavailable.',
 INTERNAL_ERROR:'An unexpected error occurred.',
};
export class ApiError extends Error {
 code:string; status:number; details?:{fields:Record<string,string>};
 constructor(code:string, details?:{fields:Record<string,string>}) {
  const known=Object.hasOwn(errorStatus,code)?code:'INTERNAL_ERROR';
  super(messages[known] || messages.INTERNAL_ERROR); this.code=known;
  this.status=errorStatus[this.code]; this.details=details;
 }
}
export function invalid(field:string,message='Invalid value.'):never {
 throw new ApiError('VALIDATION_ERROR',{fields:{[field]:message}});
}
export function normalizeError(value:unknown):ApiError {
 return value instanceof ApiError ? value : new ApiError('INTERNAL_ERROR');
}
export function errorEnvelope(error:ApiError,requestId:string) {
 return {error:{code:error.code,message:error.message,request_id:requestId,...(error.details ? {details:error.details}: {})}};
}
