import {dimensions,labels} from '../_shared/feedback/schema.ts';
import type {FeedbackOutput,ResponseInput} from '../_shared/feedback/schema.ts';
export function responses(answered=20):ResponseInput[]{return Array.from({length:20},(_,i)=>({position:i+1,word:'Word '+(i+1),answer:i<answered?'A person takes a practical step.':'',status:i<answered?'answered':'not_attempted'}));}
export function validFeedback(input:ResponseInput[]=responses()):FeedbackOutput {
 const scored=input.filter(r=>r.status==='answered'&&r.answer.trim()).map(r=>r.position);
 return {sentences:input.map(r=>{
  const answered=scored.includes(r.position),item:Record<string,any>={position:r.position,status:answered?'scored':'not_scored'};
  for(const d of dimensions){item[d+'_rating']=answered?4:null;item[d+'_label']=answered?labels[d][3]:null;item[d+'_note']=answered?'The wording describes a practical, understandable response.':null;}
  return {...item,strength:answered?'The response states an action clearly.':null,feedback:answered?'Name one concrete situation to make the action specific.':'No response was recorded.',safety_flags:[]};
 }),summary:{narrative:scored.length?'Recorded responses describe actions clearly.':'No responses were recorded; no rubric averages are available.',
  strengths:scored.length?[{code:'CLEAR_EXPRESSION',label:'Clear expression',evidence_positions:scored.slice(0,3)}]:[],weak_areas:[],
  next_drill:{code:'ACTOR_ACTION_DRILL',title:'Actor and action drill',instructions:'Write ten short responses naming an actor and action.',recommended_items:10}}};
}
export function providerEnvelope(output:FeedbackOutput=validFeedback()){
 return {modelVersion:'synthetic-model-v1',candidates:[{finishReason:'STOP',content:{parts:[{text:JSON.stringify(output)}]}}]};
}
