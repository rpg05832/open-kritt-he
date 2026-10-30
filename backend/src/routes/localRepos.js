import { Router } from 'express';
import { listLocalRepos, localRepoStats } from '../lib/localRepos.js';
import { localReposRoot } from '../lib/localRepos.js';
import { ProjectImports } from '../lib/projectImport.js';

const router = Router();
const importer = new ProjectImports(localReposRoot());
router.post('/import', async (req,res) => {
  const origin=req.get('origin');
  if(origin && !/^http:\/\/(localhost|127\.0\.0\.1):(5173|3002)$/.test(origin)) return res.status(403).json({error:'מקור הבקשה אינו מורשה'});
  try {
    const {action,id,name,relative,base64,offset,size,totalBytes,totalFiles,largestFile,largeApproved,files}=req.body || {};
    if(id && !/^[0-9a-f-]{36}$/.test(id)) throw new Error('מזהה ייבוא אינו תקין');
    let result;
    if(action==='start')result=await importer.start(name,{totalBytes,totalFiles,largestFile,largeApproved});
    else if(action==='chunk')result=await importer.chunk(id,relative,base64,offset,size);
    else if(action==='batch'){
      if(!Array.isArray(files)||files.length<1||files.length>32||files.reduce((n,f)=>n+(typeof f?.base64==='string'?f.base64.length:2000000),0)>1000000)throw new Error('קבוצת הקבצים גדולה מדי');
      for(const file of files)result=await importer.chunk(id,file.relative,file.base64,0,file.size);
    }
    else if(action==='file')result=await importer.file(id,relative,base64);
    else if(action==='finish')result=await importer.finish(id);
    else if(action==='cancel'){await importer.cancel(id);result={cancelled:true};}
    else throw new Error('פעולת ייבוא אינה מוכרת');
    res.json(result);
  } catch(e) {res.status(400).json({error:e.code ? 'העתקת הקובץ נכשלה; בדקו שאין שמות כפולים או נתיב שאינו תקין' : e.message});}
});

export function localRepoStatsErrorResponse(error) {
  if (['ENOENT', 'ENOTDIR'].includes(error?.code)) {
    return { status: 404, error: 'Local repository not found.' };
  }
  if (error?.code === 'ESTALE') {
    return { status: 409, error: 'Local repository changed while it was being counted. Retry the count.' };
  }
  if (['EACCES', 'EPERM'].includes(error?.code)) {
    return { status: 503, error: 'Local repository file count is unavailable.' };
  }
  return null;
}

// GET /api/local-repos — the repositories available under LOCAL_REPOS_PATH.
router.get('/', (req, res, next) => {
  try {
    res.json(listLocalRepos());
  } catch (e) {
    next(e);
  }
});

// GET /api/local-repos/:name/stats — lazy snapshot-style file count for one
// allowlisted local repository. Counting failures are handled by the standard
// error middleware; the scan form treats this preview as non-blocking.
router.get('/:name/stats', async (req, res, next) => {
  const controller = new AbortController();
  const cancelCount = () => controller.abort();
  res.once('close', cancelCount);
  res.set('Cache-Control', 'no-store');
  try {
    const stats = await localRepoStats(req.params.name, { signal: controller.signal });
    if (controller.signal.aborted) return;
    if (!stats) return res.status(404).json({ error: 'Local repository not found.' });
    res.json(stats);
  } catch (e) {
    if (controller.signal.aborted || e?.name === 'AbortError') return;
    const response = localRepoStatsErrorResponse(e);
    if (response) return res.status(response.status).json({ error: response.error });
    next(e);
  } finally {
    res.off('close', cancelCount);
  }
});

export default router;
