// Benchmark project: the SAFE counterpart. Any finding here is a false positive.
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PUBLIC = path.resolve(__dirname, 'public');

function routes(app, db) {
  app.get('/user', (req, res) => {
    db.query('SELECT * FROM users WHERE id = $1', [req.query.id], (err, rows) => res.json(rows));
  });
  app.get('/ping', (req, res) => {
    cp.execFile('ping', ['-c', '1', String(req.query.host)], (err, out) => res.send(out));
  });
  app.get('/download', (req, res) => {
    const target = path.resolve(PUBLIC, path.basename(String(req.query.file)));
    fs.readFile(target, (err, data) => res.send(data));
  });
  app.get('/login/done', (req, res) => {
    res.redirect('/dashboard');
  });
  app.get('/token', (req, res) => {
    const sessionToken = crypto.randomBytes(32).toString('hex');
    res.json({ sessionToken });
  });
}

module.exports = routes;
