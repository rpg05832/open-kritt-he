"""Debian package copyright files and shared license texts from this image."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
rows = subprocess.check_output(['dpkg-query', '-W', '-f=${Package}\t${Version}\n'], text=True).splitlines()
packages = []
texts = {}
for row in rows:
    name, version = row.split('\t', 1)
    notice = Path('/usr/share/doc') / name / 'copyright'
    notices = []
    if notice.is_file() and notice.stat().st_size < 2*1024*1024:
        text = notice.read_text(encoding='utf8', errors='replace')
        digest = hashlib.sha256(text.encode()).hexdigest()
        texts[digest] = text
        notices.append({'name': 'Debian copyright', 'hash': digest})
    packages.append({'component': sys.argv[1], 'ecosystem': 'Debian', 'name': name, 'version': version,
                     'license': 'SEE DEBIAN COPYRIGHT' if notices else 'UNKNOWN', 'notices': notices})
for notice in Path('/usr/share/common-licenses').glob('*'):
    if notice.is_file():
        text=notice.read_text(encoding='utf8', errors='replace')
        digest=hashlib.sha256(text.encode()).hexdigest()
        texts[digest]=text
print(json.dumps({'packages': packages, 'texts': texts}))
