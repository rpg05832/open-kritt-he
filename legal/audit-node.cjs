// Read public package metadata and bundled notices only. No application data.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = process.argv[2];
const label = process.argv[3];
const packages = [], texts = {}, visited = new Set();
if(root==='--os') {
  if(fs.existsSync('/lib/apk/db/installed')) {
    for(const block of fs.readFileSync('/lib/apk/db/installed','utf8').split('\n\n')) {
      const info=Object.fromEntries(block.split('\n').filter(line=>/^[PVLU]:/.test(line)).map(line=>[line[0],line.slice(2)]));
      if(info.P) packages.push({component:label,ecosystem:'Alpine',name:info.P,version:info.V,license:info.L||'UNKNOWN',homepage:info.U||null,notices:[]});
    }
    process.stdout.write(JSON.stringify({packages,texts})); process.exit(0);
  }
  const rows=require('child_process').execFileSync('dpkg-query',['-W','-f=${Package}\t${Version}\n'],{encoding:'utf8'}).trim().split('\n');
  for(const row of rows){const [name,version]=row.split('\t'); const file='/usr/share/doc/'+name+'/copyright'; let notices=[];
    if(fs.existsSync(file)){const text=fs.readFileSync(file,'utf8'); const hash=crypto.createHash('sha256').update(text).digest('hex'); texts[hash]=text; notices=[{name:'Debian copyright',hash}];}
    packages.push({component:label,ecosystem:'Debian',name,version,license:notices.length?'SEE DEBIAN COPYRIGHT':'UNKNOWN',notices});
  }
  for(const file of fs.readdirSync('/usr/share/common-licenses')){const full='/usr/share/common-licenses/'+file;if(fs.statSync(full).isFile()){const text=fs.readFileSync(full,'utf8');texts[crypto.createHash('sha256').update(text).digest('hex')]=text;}}
  process.stdout.write(JSON.stringify({packages,texts})); process.exit(0);
}
function noticeFiles(directory, depth=0) {
  const found=[];
  for (const entry of fs.readdirSync(directory, {withFileTypes:true})) {
    if (entry.isSymbolicLink()) continue;
    const file=path.join(directory, entry.name);
    if (entry.isFile() && /^(licen[sc]e|copying|notice|copyright|third.party.*notice)([._-]|$)/i.test(entry.name)) {
      if(fs.statSync(file).size > 1024*1024) continue;
      const text=fs.readFileSync(file,'utf8'); const hash=crypto.createHash('sha256').update(text).digest('hex');
      texts[hash]=text; found.push({name:path.relative(directory,file),hash});
    } else if(entry.isDirectory() && depth<1 && /^(licenses?|legal)$/i.test(entry.name)) found.push(...noticeFiles(file,depth+1));
  }
  return found;
}
function scan(directory) {
  if(!fs.existsSync(directory)) return;
  for(const entry of fs.readdirSync(directory,{withFileTypes:true})) {
    if(entry.isSymbolicLink() || !entry.isDirectory() || entry.name.startsWith('.')) continue;
    const folder=path.join(directory,entry.name);
    if(entry.name.startsWith('@')) {scan(folder);continue;}
    const manifest=path.join(folder,'package.json');
    if(!fs.existsSync(manifest)) continue;
    const real=fs.realpathSync(folder); if(visited.has(real)) continue; visited.add(real);
    const data=JSON.parse(fs.readFileSync(manifest,'utf8'));
    const license=typeof data.license==='string'?data.license:data.license?.type || (data.licenses||[]).map(l=>l.type).join(' OR ') || 'UNKNOWN';
    const notices=noticeFiles(folder);
    if(license.includes('SEE LICENSE') && fs.existsSync(path.join(folder,'README.md'))) {
      const text=fs.readFileSync(path.join(folder,'README.md'),'utf8'); const hash=crypto.createHash('sha256').update(text).digest('hex'); texts[hash]=text; notices.push({name:'README.md',hash});
    }
    packages.push({component:label,ecosystem:'npm',name:data.name||entry.name,version:data.version||'',license,notices,homepage:data.homepage||null,repository:typeof data.repository==='string'?data.repository:data.repository?.url||null});
    scan(path.join(folder,'node_modules'));
  }
}
scan(root);
process.stdout.write(JSON.stringify({packages,texts}));
