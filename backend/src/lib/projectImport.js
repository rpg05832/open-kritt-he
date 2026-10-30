import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export function safeRelativeFile(value) {
  if (typeof value !== 'string' || !value || value.length > 500 || value.includes('\\') || value.includes(':') || value.includes('\0')) throw new Error('נתיב קובץ אינו תקין');
  const parts = value.split('/');
  if (parts.some(p => !p || p === '.' || p === '..' || /[<>"|?*\x00-\x1f]/.test(p) || /[. ]$/.test(p))) throw new Error('נתיב קובץ אינו תקין');
  return parts;
}
export class ProjectImports {
  constructor(root) { this.root = root; this.sessions = new Map(); }
  async start(name, options = {}) {
    const {totalBytes=null,totalFiles=null,largestFile=0,largeApproved=false}=options;
    if(totalBytes!==null && (!Number.isSafeInteger(totalBytes)||totalBytes<0||!Number.isSafeInteger(totalFiles)||totalFiles<1||!Number.isSafeInteger(largestFile)||largestFile<0||largestFile>totalBytes))throw new Error('פרטי הייבוא אינם תקינים');
    if((totalBytes>100*1024*1024||totalFiles>4000||largestFile>4*1024*1024)&&largeApproved!==true)throw new Error('נדרש אישור מפורש לייבוא תיקייה גדולה');
    for (const [id,s] of this.sessions) if (Date.now()-s.created > 1800000) { await this.cancel(id); }
    if (this.sessions.size >= 3) throw new Error('יש יותר מדי ייבואים פעילים');
    const safeName = String(name || '').normalize('NFC').replace(/[^\p{L}\p{N}_. -]/gu,'_').replace(/^[. ]+|[. ]+$/g,'').slice(0,80);
    if (!safeName) throw new Error('שם תיקייה חסר');
    await fs.mkdir(this.root,{recursive:true});
    if(totalBytes!==null){const disk=await fs.statfs(this.root);if(totalBytes+256*1024*1024>disk.bavail*disk.bsize)throw new Error('אין מספיק שטח פנוי לייבוא ולמרווח עבודה');}
    const rootStat=await fs.lstat(this.root); if(rootStat.isSymbolicLink()) throw new Error('תיקיית היעד אינה תקינה');
    const id=randomUUID(); const dir=path.join(this.root,'.import-'+id);
    await fs.mkdir(dir,{recursive:false});
    this.sessions.set(id,{dir,name:safeName+'-'+id.slice(0,8),bytes:0,count:0,created:Date.now(),busy:false,totalBytes,totalFiles,current:null});
    return {id};
  }
  async chunk(id,relative,base64,offset,size) {
    const s=this.sessions.get(id);if(!s||s.busy||s.totalBytes===null)throw new Error('ייבוא בחלקים אינו זמין');
    const parts=safeRelativeFile(relative);
    if(!Number.isSafeInteger(offset)||offset<0||!Number.isSafeInteger(size)||size<0||typeof base64!=='string'||base64.length>1400000||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(base64))throw new Error('חלק קובץ אינו תקין');
    const data=Buffer.from(base64,'base64');
    if(data.length>1024*1024||offset+data.length>size||(!data.length&&size>0)||s.bytes+data.length>s.totalBytes||s.count>=s.totalFiles)throw new Error('גודל חלק הקובץ אינו תואם לתוכנית הייבוא');
    if(s.current && (s.current.relative!==relative||s.current.offset!==offset||s.current.size!==size))throw new Error('חלקי הקובץ הגיעו בסדר שגוי');
    if(!s.current&&offset!==0)throw new Error('הקובץ חייב להתחיל בחלק הראשון');
    s.busy=true;
    try {
      const disk=await fs.statfs(this.root);if(data.length+64*1024*1024>disk.bavail*disk.bsize)throw new Error('אין מספיק שטח פנוי להמשך ההעתקה');
      const target=path.join(s.dir,...parts);
      if(!s.current){await fs.mkdir(path.dirname(target),{recursive:true});await fs.writeFile(target,Buffer.alloc(0),{flag:'wx'});s.current={relative,offset:0,size};}
      await fs.appendFile(target,data);s.current.offset+=data.length;s.bytes+=data.length;s.created=Date.now();
      if(s.current.offset===size){s.count++;s.current=null;}
      return {bytes:s.bytes,count:s.count};
    } finally {s.busy=false;}
  }
  async file(id,relative,base64) {
    const s=this.sessions.get(id); if(!s || s.busy) throw new Error('ייבוא לא נמצא או עסוק');
    const parts=safeRelativeFile(relative);
    if(typeof base64!=='string'||base64.length>5600000||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(base64)) throw new Error('תוכן קובץ אינו תקין');
    const data=Buffer.from(base64,'base64');
    if(data.length>4*1024*1024||s.bytes+data.length>100*1024*1024||s.count>=4000) throw new Error('מגבלת הייבוא: 4 MB לקובץ, 100 MB ו־4,000 קבצים לתיקייה');
    s.busy=true;
    try { const target=path.join(s.dir,...parts); await fs.mkdir(path.dirname(target),{recursive:true}); await fs.writeFile(target,data,{flag:'wx'}); s.bytes+=data.length;s.count++;return {count:s.count}; } finally {s.busy=false;}
  }
  async finish(id) {
    const s=this.sessions.get(id);if(!s||s.busy||!s.count||s.current||(s.totalBytes!==null&&(s.bytes!==s.totalBytes||s.count!==s.totalFiles)))throw new Error('הייבוא טרם הושלם או אינו זמין');
    s.busy=true;
    try {await fs.rename(s.dir,path.join(this.root,s.name));this.sessions.delete(id);return {name:s.name,count:s.count,bytes:s.bytes};}catch(e){s.busy=false;throw e;}
  }
  async cancel(id) {const s=this.sessions.get(id);if(!s||s.busy)return;await fs.rm(s.dir,{recursive:true,force:true});this.sessions.delete(id);}
}
