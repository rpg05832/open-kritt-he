/* global console */
import fs from 'node:fs';
import path from 'node:path';
import { parse } from '@babel/parser';
const values = new Set();
function walk(n) {
  if (!n || typeof n !== 'object') return;
  if (['JSXText','StringLiteral'].includes(n.type)) {
    const s=n.value.replace(/\s+/g,' ').trim();
    if (/[a-zA-Z]/.test(s) && (n.type==='JSXText'|| /^[A-Z]/.test(s)||s.includes(' ')) && !/^(var\(|https?:|[.#/]|[0-9]|rgba?\(|linear-|repeat\(|SELECT|INSERT|UPDATE)/.test(s) && s.length<600) values.add(s);
  }
  for (const [k,v] of Object.entries(n)) if(k!=='loc'&&k!=='extra') if(Array.isArray(v)) v.forEach(walk); else if(v&&typeof v==='object') walk(v);
}
function visit(dir) { for(const f of fs.readdirSync(dir,{withFileTypes:true})) {const p=path.join(dir,f.name);if(f.isDirectory())visit(p);else if(/\.(jsx|js)$/.test(p)&&!p.includes('.test.')) walk(parse(fs.readFileSync(p,'utf8'),{sourceType:'module',plugins:['jsx']}));}}
visit('src'); fs.writeFileSync('ui-strings.json',JSON.stringify([...values].sort(),null,2)); console.log(values.size);
