import {ApiError} from '../errors.ts';
export function classifyFailure(error:unknown):{code:string;retryable:boolean}{
 const code=error instanceof ApiError?error.code:'INTERNAL_ERROR';
 return {code:['AI_OUTPUT_INVALID','PROVIDER_UNAVAILABLE','GLOBAL_QUOTA_EXHAUSTED','AI_CONSENT_REQUIRED','FEATURE_DISABLED'].includes(code)?code:'INTERNAL_ERROR',
  retryable:['AI_OUTPUT_INVALID','PROVIDER_UNAVAILABLE'].includes(code)||!(error instanceof ApiError)};
}
