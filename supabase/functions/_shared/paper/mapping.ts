import {ApiError} from '../errors.ts';
export interface OcrLine {text:string;confidence:number|null}
export interface Draft {position:number;ocr_text:string;confidence:number|null;needs_review:boolean}
export function validateLines(value:unknown):OcrLine[]{
 if(!Array.isArray(value)||value.length>500)throw new ApiError('OCR_FAILED');let total=0;
 for(const row of value){if(!row||typeof row.text!=='string'||[...row.text].length>10000||
   row.confidence!==null&&(!Number.isFinite(row.confidence)||row.confidence<0||row.confidence>1))throw new ApiError('OCR_FAILED');total+=row.text.length;}
 if(total>200000)throw new ApiError('OCR_FAILED');return value.map(row=>({text:row.text,confidence:row.confidence}));
}
export function mapLines(input:OcrLine[]):Draft[]{
 const lines=validateLines(input),draft:Draft[]=Array.from({length:20},(_,i)=>({position:i+1,ocr_text:'',confidence:null,needs_review:true}));
 const numbered=lines.some(line=>/^\s*\d{1,3}\s*[.)-]/.test(line.text));const seen=new Set<number>();let current:number|undefined,previous=0,sequential=0;
 function append(position:number,text:string,confidence:number|null,uncertain:boolean){const row=draft[position-1],duplicate=seen.has(position);
  row.ocr_text+=row.ocr_text?'\n'+text:text;row.confidence=row.confidence===null?confidence:confidence===null?null:Math.min(row.confidence,confidence);
  row.needs_review=duplicate||uncertain||confidence===null||confidence<0.8||!text.trim();seen.add(position);
  if([...row.ocr_text].length>10000)throw new ApiError('OCR_FAILED');
 }
 for(const line of lines){if(!line.text.trim())continue;
  const match=/^\s*(\d{1,3})\s*[.)-]\s*(.*)$/.exec(line.text);
  if(numbered&&match&&Number(match[1])>=1&&Number(match[1])<=20){
   current=Number(match[1]);const gap=previous===0?current!==1:current!==previous+1;
   if(gap&&previous>0)draft[previous-1].needs_review=true;
   append(current,match[2],line.confidence,gap);previous=current;
  }else if(numbered){
   const position=current??1,row=draft[position-1];
   if(current!==undefined&&/^\s{2,}\S/.test(line.text)&&!match&&row.ocr_text){
    row.ocr_text+=' '+line.text.trim();row.confidence=row.confidence===null||line.confidence===null?null:Math.min(row.confidence,line.confidence);
    row.needs_review=row.needs_review||row.confidence===null||row.confidence<0.8;
    if([...row.ocr_text].length>10000)throw new ApiError('OCR_FAILED');
   }else append(position,line.text,line.confidence,true);
  }else {sequential++;append(Math.min(sequential,20),line.text,line.confidence,true);}
 }
 return draft;
}
