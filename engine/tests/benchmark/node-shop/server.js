// Benchmark project: deliberately vulnerable Express app. Never run it.
const express = require('express');
const cp = require('child_process');
const fs = require('fs');
const db = require('./db');

const app = express();

app.get('/user', (req, res) => {
  db.query('SELECT * FROM users WHERE id = ' + req.query.id, (err, rows) => res.json(rows));
});

app.get('/ping', (req, res) => {
  cp.exec(`ping -c 1 ${req.query.host}`, (err, out) => res.send(out));
});

app.get('/download', (req, res) => {
  fs.readFile(req.query.file, (err, data) => res.send(data));
});

app.get('/login/done', (req, res) => {
  res.redirect(req.query.next);
});

app.get('/preview', (req, res) => {
  res.send(eval(req.query.expression));
});

module.exports = app;
