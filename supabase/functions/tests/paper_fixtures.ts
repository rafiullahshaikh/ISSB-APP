// Generated 2x2 solid-color images; no candidate data or metadata.
export const fixtures={
 'image/png':'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGMUSdnCwMDAxAAGAA2aATD8jyILAAAAAElFTkSuQmCC',
 'image/jpeg':'/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDlKKKK+vPlT//Z',
 'image/webp':'UklGRjwAAABXRUJQVlA4IDAAAADwAQCdASoCAAIAAUAmJaACdLoB+AAETAAA/vDXA/9Js8TZ4mz5JH/zsGxLteAAAAA=',
};
export const imageBytes=(mime:keyof typeof fixtures='image/png')=>Uint8Array.from(atob(fixtures[mime]),v=>v.charCodeAt(0));
export async function imageRecord(mime:keyof typeof fixtures='image/png'){
 const bytes=imageBytes(mime),id='00000000-0000-0000-0000-000000000401',user_id='00000000-0000-0000-0000-000000000402',session_id='00000000-0000-0000-0000-000000000403';
 const sha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 return {id,user_id,session_id,bucket_id:'paper-uploads',object_path:`paper-pages/${user_id}/${session_id}/${id}.${mime==='image/jpeg'?'jpg':mime==='image/png'?'png':'webp'}`,
  content_type:mime,size_bytes:bytes.length,sha256,expires_at:new Date(Date.now()+86400000).toISOString(),upload_expires_at:new Date(Date.now()+900000).toISOString(),uploaded_at:new Date().toISOString(),status:'uploaded',lines:null};
}
export const visionPayload=(text='1. PRIVATE-OCR draft.\n2. A clear action.')=>({responses:[{fullTextAnnotation:{text}}]});
