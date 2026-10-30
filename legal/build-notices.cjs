const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=path.resolve(__dirname,'..'), out=path.join(root,'frontend/public/legal');
fs.mkdirSync(path.join(out,'texts'),{recursive:true});
const read=p=>JSON.parse(fs.readFileSync(p,'utf8').replace(/^\uFEFF/,''));
const packages=[],texts={};
for(const file of fs.readdirSync(path.join(__dirname,'raw')).filter(f=>f.endsWith('.json')&&f!=='agent-skills.json')){
 const data=read(path.join(__dirname,'raw',file)); packages.push(...data.packages);Object.assign(texts,data.texts);
}
const apk=fs.readFileSync(path.join(__dirname,'raw/database-apk-installed.txt'),'utf8');
for(const block of apk.split(/\r?\n\r?\n/)){
 const p=Object.fromEntries(block.split(/\r?\n/).filter(l=>/^[PVLU]:/.test(l)).map(l=>[l[0],l.slice(2)]));
 if(p.P){const virtual=block.includes('T:virtual meta package')&&/^I:0$/m.test(block.replaceAll('\r',''))&&!/^R:/m.test(block);packages.push({component:'database-os',ecosystem:'Alpine',name:p.P,version:p.V,license:virtual?'NOT-APPLICABLE (empty virtual metapackage)':p.L||'UNKNOWN',virtualMeta:virtual,notices:[],homepage:p.U});}
}
function addText(name,text){const hash=crypto.createHash('sha256').update(text).digest('hex');texts[hash]=text;return {name,hash};}
for(const component of ['frontend','backend']){
 const lock=read(path.join(root,component,'package-lock.json'));
 for(const [key,p] of Object.entries(lock.packages||{})){
  if(!key)continue;const name=p.name||key.split('node_modules/').at(-1);
  if(packages.some(row=>row.name===name&&row.version===p.version&&row.component.startsWith(component)))continue;
  packages.push({component:component+'-lock-declared',ecosystem:'npm',name,version:p.version,license:p.license||'UNKNOWN',notices:[],declaredOnly:true});
 }
}
for(const p of packages){
 p.declaredLicense=p.license;
 if(p.license==='UNKNOWN'){
  const text=(p.notices||[]).map(n=>texts[n.hash]||'').join('\n');
  if(text.includes('Permission is hereby granted, free of charge'))p.license='MIT';
  else if(text.includes('Redistribution and use in source and binary forms'))p.license=/Neither the name|BSD 3-Clause|names? of (?:its|the) contributors/i.test(text)?'BSD-3-Clause':'BSD-2-Clause';
  if(p.license!=='UNKNOWN')p.evidence='Identified from the bundled license text, not inferred from package popularity.';
 }
 p.review=p.virtualMeta?'not-applicable':p.license==='UNKNOWN'?'unresolved':/SEE LICENSE|Proprietary/i.test(p.license)?'vendor-terms':/SEE DEBIAN|GPL|MPL|CC-BY/i.test(p.license)?'conditions-required':'notices-required';
}
function vendor(name,license,file,homepage,review='notices-required'){
 packages.push({component:'external-tools-and-assets',ecosystem:'external',name,version:'see installed image inventory',license,homepage,review,notices:file?[addText(path.basename(file),fs.readFileSync(path.join(__dirname,'vendor',file),'utf8'))]:[]});
}
vendor('Geist / Geist Mono fonts','OFL-1.1','Geist-OFL-1.1.txt','https://github.com/vercel/geist-font');
vendor('Node.js runtime and bundled third-party code','SEE NODE LICENSE','Node-LICENSE.txt','https://github.com/nodejs/node','conditions-required');
vendor('CPython runtime','PSF-2.0 AND bundled notices','Python-LICENSE.txt','https://github.com/python/cpython','conditions-required');
vendor('PostgreSQL server','PostgreSQL','PostgreSQL-COPYRIGHT.txt','https://github.com/postgres/postgres');
vendor('Docker CLI','Apache-2.0','Docker-CLI-Apache-2.0.txt','https://github.com/docker/cli','conditions-required');
vendor('Cursor Agent','Proprietary vendor terms',null,'https://cursor.com/terms-of-service','vendor-terms');
vendor('Claude Code CLI (installed from npm at build time, not bundled)','Proprietary - Anthropic terms',null,'https://www.anthropic.com/legal/commercial-terms','vendor-terms');
vendor('Grok Build CLI (optional, off by default, downloaded at build time; source code Apache-2.0 at github.com/xai-org/grok-build, official binary also subject to x.ai terms)','Apache-2.0 source; binary under x.ai terms',null,'https://github.com/xai-org/grok-build','vendor-terms');
vendor('Docker Desktop (host prerequisite, not bundled)','Separate subscription / vendor terms',null,'https://www.docker.com/legal/docker-subscription-service-agreement/','vendor-terms');
vendor('Codex CLI','Apache-2.0','Codex-Apache-2.0.txt','https://github.com/openai/codex');
vendor('Gitleaks (secret scanner, downloaded at build time, version in engine/security-tools.json)','MIT','Gitleaks-MIT.txt','https://github.com/gitleaks/gitleaks');
vendor('OSV-Scanner (dependency scanner, downloaded at build time)','Apache-2.0','OSV-Scanner-Apache-2.0.txt','https://github.com/google/osv-scanner');
vendor('Trivy (configuration scanner, downloaded at build time)','Apache-2.0','Trivy-Apache-2.0.txt','https://github.com/aquasecurity/trivy');
vendor('Trivy NOTICE (required by Apache-2.0 section 4d)','Apache-2.0 NOTICE','Trivy-NOTICE.txt','https://github.com/aquasecurity/trivy/blob/main/NOTICE');
vendor('Trivy built-in misconfiguration checks (trivy-checks, embedded in the Trivy binary)','MIT',null,'https://github.com/aquasecurity/trivy-checks','notices-required');
vendor('Ruff (Python code-quality checker, installed at build time)','MIT','Ruff-MIT.txt','https://github.com/astral-sh/ruff');
vendor('Lizard (complexity analyzer, installed at build time)','MIT','Lizard-MIT.txt','https://github.com/terryyin/lizard');
vendor('Biome (JavaScript/TypeScript linter, installed at build time)','MIT OR Apache-2.0','Biome-MIT.txt','https://github.com/biomejs/biome');
vendor('jscpd (duplicate code detector, installed at build time)','MIT','jscpd-MIT.txt','https://github.com/kucherenko/jscpd');
for(const file of fs.readdirSync(path.join(__dirname,'vendor/cursor'))){vendor('Cursor bundled third-party notice: '+file,'SEE BUNDLED NOTICE','cursor/'+file,'https://cursor.com/terms-of-service','conditions-required');}
for(const [name,file,url,license] of [
 ['Cloudflare skill references','Cloudflare-MIT.txt','https://github.com/cloudflare/security-audit-skill','MIT'],
 ['GitHub skill references','GitHub-skills-MIT.txt','https://github.com/github/awesome-copilot','MIT'],
 ['Pashov skill references','Pashov-skills-MIT.txt','https://github.com/pashov/skills','MIT'],
 ['Trail of Bits skill references','Trail-of-Bits-CC-BY-SA-4.0.txt','https://github.com/trailofbits/skills','CC-BY-SA-4.0'],
 ['Sentry skill references','Sentry-skills-Apache-2.0.txt','https://github.com/getsentry/skills','Apache-2.0'],
 ['Factory skill references','Factory-skills-MIT.txt','https://github.com/Factory-AI/skills','MIT'],
 ['Netresearch skill code references','Netresearch-MIT.txt','https://github.com/netresearch/security-audit-skill/blob/main/LICENSE-MIT','MIT'],
 ['Netresearch skill document references','Netresearch-CC-BY-SA-4.0.txt','https://github.com/netresearch/security-audit-skill/blob/main/LICENSE-CC-BY-SA-4.0','CC-BY-SA-4.0']])vendor(name,license,file,url,'conditions-required');
const skills=read(path.join(__dirname,'raw/agent-skills.json'));
for(const skill of skills)if(skill.slug.startsWith('he-')){skill.licenseSpdx='AGPL-3.0-only';skill.attribution='הגרסה העברית, התוספות והשיפורים בוצעו על ידי @ארי ממתמחים טופ.';skill.sourceUrl='https://mitmachim.top/user/%D7%90%D7%A8%D7%99';}
const issues=[
 {id:'vendor-redistribution',severity:'blocker-for-binary-redistribution',text:'Claude Code ו־Cursor Agent אינם ברישיון AGPL. אין בדוח אישור להפיץ מחדש את הקבצים הבינאריים או תמונות Docker הכוללות אותם. יש לברר הרשאה אצל הספק או להפיץ קוד והוראות התקנה בלבד.'},
 {id:'container-source-obligations',severity:'blocker-for-image-redistribution',text:'רכיבי GPL/LGPL/MPL וחבילות מערכות ההפעלה דורשים בדיקת חובות מקור, הודעות וגרסאות לפני הפצת תמונות Docker. נאספו הודעות קיימות, אך לא הוכנה חבילת מקור מלאה לכל הבינאריים שבתמונות.'},
 {id:'transitive-binaries',severity:'review-required',text:'הסריקה מבוססת על חבילות מותקנות, קובצי נעילה וטקסטי רישוי זמינים. אינה מפרקת כל בינארי או מאתרת כל העתק קוד מוטמע; ספקי הכלים עשויים לכלול רכיבי צד שלישי נוספים.'},
 {id:'source-publication',severity:'before-publication',text:'בהפצת גרסה נגזרת יש לשמור AGPL והודעות מקור, לציין שינויים ותאריך ולהנגיש את המקור המתאים. בהפעלה ברשת יש להציע למשתמשים את מקור הגרסה המותאמת. כתובת מאגר ההפצה שלכם עדיין לא הוגדרה.'}
];
const unresolved=packages.filter(p=>p.review==='unresolved');
if(unresolved.length)issues.push({id:'missing-license',severity:'review-required',text:`נותרו ${unresolved.length} רשומות ללא זיהוי רישיון חד־משמעי. ראו את רשימת הרכיבים.`});
// Hashes ignore line endings and BOM, so a Windows checkout and the LF files in the
// distribution produce the same values.
const inputHashes={};for(const file of ['LICENSE','frontend/package-lock.json','backend/package-lock.json','engine/requirements.txt','engine/Dockerfile','frontend/Dockerfile','backend/Dockerfile','database/Dockerfile','executor-view/Dockerfile']){inputHashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file),'utf8').replace(/^\uFEFF/,'').replace(/\r\n/g,'\n'),'utf8').digest('hex');}
const inventory={generatedAt:new Date().toISOString(),auditStatus:'REVIEW_REQUIRED_NOT_LEGAL_CLEARANCE',inputHashes,
 credit:{name:'@ארי',community:'מתמחים טופ',profile:'https://mitmachim.top/user/%D7%90%D7%A8%D7%99',email:'rpg05832@gmail.com'},
 upstream:{name:'open·kritt',url:'https://github.com/Kritt-ai/open-kritt',owners:['Harel Rom','Gabriel Balko'],license:'AGPL-3.0-only'},
 summary:{packageRecords:packages.length,uniquePackages:new Set(packages.map(p=>`${p.ecosystem}:${p.name}@${p.version}`)).size,noticeTexts:Object.keys(texts).length,unresolved:unresolved.length},issues,skills,packages};
for(const [hash,text] of Object.entries(texts))fs.writeFileSync(path.join(out,'texts',hash+'.txt'),text);
fs.writeFileSync(path.join(out,'inventory.json'),JSON.stringify(inventory,null,2));
for(const name of ['LICENSE','OWNERSHIP.md','CONTRIBUTION_TERMS.md'])fs.copyFileSync(path.join(root,name),path.join(out,name));
let markdown='# Third-party notices / הודעות צד שלישי\n\nGenerated: '+inventory.generatedAt+'\n\n';
markdown+='הגרסה העברית, התוספות והשיפורים בוצעו על ידי [@ארי ממתמחים טופ]('+inventory.credit.profile+'). מייל: '+inventory.credit.email+'.\n\n';
markdown+='Original open·kritt: Harel Rom and Gabriel Balko; AGPL-3.0-only. Original copyright and license notices remain in force. This adaptation is not an official upstream release.\n\n';
markdown+='## Distribution review / מצב בדיקת ההפצה\n\n'+issues.map(i=>'- '+i.text).join('\n')+'\n\n';
markdown+='License texts are retained under frontend/public/legal/texts/<SHA256>.txt. Hashes below refer to the exact captured texts. A license expression is not a blanket permission to redistribute a complete image.\n\n';
markdown+='|Component|Package|Version|License|Notice text SHA256|\n|---|---|---|---|---|\n';
for(const p of packages)markdown+=`|${p.component}|${p.name}|${p.version}|${p.license.replaceAll('|','/')}|${p.notices.map(n=>n.hash).join(', ')}|\n`;
fs.writeFileSync(path.join(root,'THIRD_PARTY_NOTICES.md'),markdown);
fs.writeFileSync(path.join(out,'THIRD_PARTY_NOTICES.md'),markdown);
console.log(JSON.stringify(inventory.summary));
