export const RUBRIC_VERSION='wat-rubric-v1';
export const DISCLAIMER='This is AI-assisted practice feedback, not an official ISSB assessment, psychological evaluation, or selection prediction.';
export const dimensions=['tone','agency','clarity','realism'] as const;
export const labels={tone:['discouraging','negative','neutral','constructive','balanced'],
 agency:['passive','limited','developing','active','purposeful'],clarity:['unclear','fragmented','understandable','clear','precise'],
 realism:['implausible','exaggerated','plausible','grounded','practical']};
export const safetyFlags=['self_harm','violence','other_sensitive'];
type Schema=Record<string,any>;
const string=(maxLength:number):Schema=>({type:'string',minLength:1,maxLength});
const enumeration=(values:string[]):Schema=>({type:'string',enum:values});
const object=(properties:Record<string,Schema>):Schema=>({type:'object',properties,required:Object.keys(properties),additionalProperties:false});
const array=(items:Schema,minItems:number,maxItems:number):Schema=>({type:'array',items,minItems,maxItems});
const nullable=(schema:Schema):Schema=>({anyOf:[schema,{type:'null'}]});
const evidence=array({type:'integer',minimum:1,maximum:20},1,20);
const sentence:Record<string,Schema>={position:{type:'integer',minimum:1,maximum:20},status:enumeration(['scored','not_scored'])};
for(const d of dimensions){sentence[d+'_rating']=nullable({type:'integer',minimum:1,maximum:5});
 sentence[d+'_label']=nullable(enumeration(labels[d]));sentence[d+'_note']=nullable(string(500));}
sentence.strength=nullable(string(1000));sentence.feedback=string(2000);sentence.safety_flags=array(enumeration(safetyFlags),0,3);
export const outputSchema=object({sentences:array(object(sentence),20,20),summary:object({narrative:string(4000),
 strengths:array(object({code:enumeration(['CLEAR_EXPRESSION','CONSTRUCTIVE_FRAMING','ACTIVE_RESPONSE','PRACTICAL_FRAMING']),label:string(160),evidence_positions:evidence}),0,5),
 weak_areas:array(object({code:enumeration(['LOW_SPECIFICITY','LOW_CLARITY','LOW_AGENCY','LOW_REALISM','NEGATIVE_FRAMING']),label:string(160),evidence_positions:evidence,recommendation:string(1000)}),0,5),
 next_drill:object({code:enumeration(['ACTOR_ACTION_DRILL','CLARITY_DRILL','PRACTICAL_RESPONSE_DRILL']),title:string(160),instructions:string(1000),recommended_items:{type:'integer',minimum:1,maximum:20}})})});
export interface ResponseInput {position:number;word:string;answer:string;status:string}
export interface FeedbackOutput {sentences:Record<string,any>[];summary:Record<string,any>}
