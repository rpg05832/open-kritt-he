// Test fixture for security_rules.json. Deliberately vulnerable; never executed.
// "ruleid:" = the next line must be reported, "ok:" = it must not be.
const cp = require('child_process');
const fs = require('fs');
const jwt = require('jsonwebtoken');

function handler(req, res, db, el, name) {
  // ruleid: javascript-command-injection
  cp.exec(`ls ${req.query.dir}`);
  // ruleid: javascript-command-injection
  cp.exec('ls ' + name);
  // ok: javascript-command-injection
  cp.execFile('ls', [name]);
  // ruleid: javascript-new-function
  const f = new Function('a', name);
  // ruleid: javascript-innerhtml
  el.innerHTML = name;
  // ok: javascript-innerhtml
  el.innerHTML = '';
  // ruleid: javascript-sql-string-building
  db.query('SELECT * FROM t WHERE id = ' + req.params.id);
  // ruleid: javascript-sql-string-building
  db.query(`SELECT * FROM t WHERE id = ${name}`);
  // ok: javascript-sql-string-building
  db.query('SELECT * FROM t WHERE id = $1', [name]);
  // ruleid: javascript-path-from-request
  fs.readFile(req.query.file, () => {});
  // ok: javascript-path-from-request
  fs.readFile('./static/index.html', () => {});
  // ruleid: javascript-open-redirect
  res.redirect(req.query.next);
  // ok: javascript-open-redirect
  res.redirect('/home');
  // ruleid: javascript-tls-env-disabled
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
  // ruleid: javascript-jwt-no-verify
  jwt.decode(name);
  // ruleid: javascript-insecure-random-secret
  const sessionToken = Math.random().toString(36);
  // ok: javascript-insecure-random-secret
  const offset = Math.random() * 10;
  // ruleid: javascript-dynamic-eval
  eval(name);
  // ruleid: javascript-tls-disabled
  const agentOptions = { host: name, rejectUnauthorized: false };
  // ok: javascript-tls-disabled
  const strictOptions = { host: name, rejectUnauthorized: true };
  void agentOptions;
  void strictOptions;
  return [f, sessionToken, offset];
}

module.exports = handler;
