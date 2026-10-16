import {ApiError} from '../errors.ts';
import {dimensions,outputSchema} from './schema.ts';
import type {FeedbackOutput,ResponseInput} from './schema.ts';
const invalid=():never=>{throw new ApiError('AI_OUTPUT_INVALID');};
function validate(value:any,schema:Record<string,any>):void {
 if(schema.anyOf){for(const option of schema.anyOf)try{validate(value,option);return;}catch{}invalid();}
 if(schema.type==='null'){if(value!==null)invalid();return;}
 if(schema.type==='object'){
  if(!value || typeof value!=='object' || Array.isArray(value))invalid();
  if(Object.keys(value).some(k=>!Object.hasOwn(schema.properties,k)) || schema.required.some((k:string)=>!Object.hasOwn(value,k)))invalid();
  for(const [k,s] of Object.entries(schema.properties))validate(value[k],s as Record<string,any>);
 }else if(schema.type==='array'){
  if(!Array.isArray(value)||value.length<schema.minItems||value.length>schema.maxItems)invalid();
  for(const item of value)validate(item,schema.items);
 }else if(schema.type==='string'){
  if(typeof value!=='string'||/[\uD800-\uDFFF\u0000]/u.test(value)||
   (schema.minLength && [...value].length<schema.minLength)||(schema.maxLength && [...value].length>schema.maxLength)||
   (schema.enum&&!schema.enum.includes(value)))invalid();
 }else if(schema.type==='integer'&&(!Number.isSafeInteger(value)||value<schema.minimum||value>schema.maximum))invalid();
}
// Defense in depth for generated guidance. Candidate responses themselves are never scanned as provider claims.
export function assertSafeGuidance(value:string):void {
 const normalized=value.normalize('NFKC').toLowerCase().replace(/[^a-z0-9%]+/g,' ');
 const forbidden=[/\b(?:issb|diagnos(?:is|ed|e|tic)|medical advice|psychological evaluation|personality classification)\b/,/\b(?:personality|mental health|psychological) (?:type|profile|disorder|classification|assessment|evaluation)\b/,
  /\b(?:you|candidate) (?:are|is|have|has) (?:a |an )?(?:depressed|narcissist|psychopath|sociopath|unfit|suitable|unsuitable)\b/,
  /\b(?:official|guaranteed|perfect) (?:issb|military|selection|assessment|sentence|success|result|outcome)\b/,
  /\b(?:selection|selected|passing|pass|success) (?:chance|probability|likelihood|odds|rate|guarantee)\b/,
  /\b(?:will|guaranteed to) (?:pass|succeed|be selected)\b/,/\b\d+ ?%/,/\b(?:take|stop taking|prescribe) (?:medication|medicine|pills)\b/,
  /\b(?:political|ideological|religious) (?:profile|beliefs|loyalty|classification|affiliation)\b/,
  /\baggression (?:is|shows|means) (?:always )?(?:positive|strength|leadership|good)\b/];
 if(forbidden.some(rule=>rule.test(normalized)))invalid();
}
export function validateOutput(value:unknown,responses:ResponseInput[]):FeedbackOutput {
 validate(value,outputSchema);const result=value as FeedbackOutput;
 if(responses.length!==20)invalid();
 const scored=new Set<number>();
 result.sentences.forEach((item,index)=>{
  const response=responses[index];if(item.position!==index+1||response.position!==index+1)invalid();
  const answered=response.status==='answered'&&response.answer.trim().length>0;
  if(answered){if(item.status!=='scored'||item.strength===null)invalid();scored.add(item.position);
   for(const d of dimensions)if(item[d+'_rating']===null||item[d+'_label']===null||item[d+'_note']===null)invalid();
  }else{
   if(item.status!=='not_scored'||item.strength!==null||item.feedback!=='No response was recorded.'||item.safety_flags.length)invalid();
   for(const d of dimensions)if(item[d+'_rating']!==null||item[d+'_label']!==null||item[d+'_note']!==null)invalid();
  }
  if(new Set(item.safety_flags).size!==item.safety_flags.length)invalid();
  for(const key of ['strength','feedback',...dimensions.map(d=>d+'_note')])if(typeof item[key]==='string')assertSafeGuidance(item[key]);
 });
 for(const list of [result.summary.strengths,result.summary.weak_areas])for(const item of list){
  if(new Set(item.evidence_positions).size!==item.evidence_positions.length||item.evidence_positions.some((p:number)=>!scored.has(p)))invalid();
  assertSafeGuidance(item.label);if(item.recommendation)assertSafeGuidance(item.recommendation);
 }
 assertSafeGuidance(result.summary.narrative);assertSafeGuidance(result.summary.next_drill.title);assertSafeGuidance(result.summary.next_drill.instructions);
 return result;
}
