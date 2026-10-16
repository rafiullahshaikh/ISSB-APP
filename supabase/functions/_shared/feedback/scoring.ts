import {dimensions} from './schema.ts';
import type {FeedbackOutput} from './schema.ts';
const round=(n:number)=>Math.round((n+Number.EPSILON)*10)/10;
export function scoreFeedback(output:FeedbackOutput){
 const scored=output.sentences.filter(s=>s.status==='scored');
 const scores=Object.fromEntries(dimensions.map(d=>[d,scored.length?round(scored.reduce((sum,s)=>sum+s[d+'_rating'],0)*2/scored.length):null]));
 return {overall:scored.length?round(scored.reduce((sum,s)=>sum+dimensions.reduce((n,d)=>n+s[d+'_rating'],0)/2,0)/scored.length):null,
  dimensions:scores,sentences:output.sentences.map(s=>s.status==='scored'?round(dimensions.reduce((sum,d)=>sum+s[d+'_rating'],0)/2):null)};
}
export function scoreLabel(score:number|null,dimension?:string):string {
 if(score===null)return 'No scored responses';
 if(dimension){const names:Record<string,string[]>={tone:['Developing','Neutral','Constructive'],agency:['Developing','Participating','Active'],clarity:['Developing','Understandable','Clear'],realism:['Developing','Plausible','Grounded']};return names[dimension][score>=8?2:score>=6?1:0];}
 return score>=8?'Strong practice response pattern':score>=6?'Developing practice response pattern':'Practice response pattern needs development';
}
