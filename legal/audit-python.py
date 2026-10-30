"""Installed Python distributions, retaining their shipped license texts."""
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys
packages = []
texts = {}
for distribution in importlib.metadata.distributions():
    metadata = distribution.metadata
    expression = metadata.get('License-Expression') or metadata.get('License') or 'UNKNOWN'
    if len(expression) > 300:
        expression = 'SEE BUNDLED LICENSE TEXT'
    notices = []
    for file in distribution.files or []:
        if not any(part.endswith('.dist-info') or part.endswith('.egg-info') for part in file.parts):
            continue
        if not any(word in file.name.lower() for word in ('license', 'licence', 'copying', 'notice', 'copyright')):
            continue
        source = Path(distribution.locate_file(file))
        if not source.is_file() or source.stat().st_size > 1024*1024:
            continue
        text = source.read_text(encoding='utf8', errors='replace')
        digest = hashlib.sha256(text.encode()).hexdigest()
        texts[digest] = text
        notices.append({'name': file.name, 'hash': digest})
    packages.append({'component': sys.argv[1], 'ecosystem': 'PyPI', 'name': metadata['Name'],
                     'version': distribution.version, 'license': expression,
                     'classifiers': metadata.get_all('Classifier') or [], 'notices': notices,
                     'homepage': metadata.get('Home-page'), 'projectUrls': metadata.get_all('Project-URL') or []})
print(json.dumps({'packages': packages, 'texts': texts}))
