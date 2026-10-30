# Test fixture for engine/open_kritt_engine/security_rules.json. Deliberately
# vulnerable; never imported or executed. "ruleid:" = the next line must be
# reported by that rule, "ok:" = the next line must NOT be reported by it.
import hashlib
import marshal
import os
import pickle
import subprocess
import tempfile

import jinja2
import requests
import yaml


def handler(cursor, user_id, app, data, path):
    # ruleid: python-sql-string-building
    cursor.execute(f"SELECT * FROM users WHERE id = {user_id}")
    # ruleid: python-sql-string-building
    cursor.execute("SELECT * FROM users WHERE id = %s" % user_id)
    # ok: python-sql-string-building
    cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))
    # ruleid: python-yaml-unsafe-load
    yaml.load(data)
    # ok: python-yaml-unsafe-load
    yaml.load(data, Loader=yaml.SafeLoader)
    # ruleid: python-tls-verify-disabled
    requests.get("https://example.com", verify=False)
    # ok: python-tls-verify-disabled
    requests.get("https://example.com")
    # ruleid: python-os-command
    os.system("ls " + path)
    # ok: python-os-command
    os.system("ls")
    # ruleid: python-dynamic-code
    eval(data)
    # ok: python-dynamic-code
    eval("1 + 1")
    # ruleid: python-flask-debug
    app.run(debug=True)
    # ruleid: python-jinja-autoescape-off
    jinja2.Environment(autoescape=False)
    # ruleid: python-insecure-tempfile
    tempfile.mktemp()
    # ruleid: python-weak-password-hash
    hashlib.md5(data)
    # ruleid: python-shell-command
    subprocess.run(path, shell=True)
    # ok: python-shell-command
    subprocess.run(["ls", path])
    # ruleid: python-unsafe-pickle
    pickle.loads(data)
    # ruleid: python-unsafe-deserialization
    marshal.loads(data)
