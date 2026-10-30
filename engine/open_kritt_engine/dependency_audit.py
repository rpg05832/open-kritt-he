"""Bounded OSV queries; never install dependencies or execute repository scripts."""
import hashlib
import json
import os
import re
import time
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

SKIP = {'.git', 'node_modules', '.venv', 'venv', 'dist', 'build', '.next', '__pycache__'}


def dependency_inventory(root, limit=500):
    packages = {}
    files = []
    incomplete = False
    started = time.monotonic()
    visited = 0
    def add(ecosystem, name, version, source):
        nonlocal incomplete
        if len(packages) >= limit:
            incomplete = True
            return
        if not isinstance(version, str) or not re.fullmatch(r'[0-9][A-Za-z0-9.+_-]{0,100}', version):
            return
        if not isinstance(name, str) or not re.fullmatch(r'[@A-Za-z0-9][A-Za-z0-9@/_.-]{0,200}', name):
            return
        packages.setdefault((ecosystem, name, version), {'ecosystem': ecosystem, 'name': name, 'version': version, 'file': source})
    for directory, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and not Path(directory, d).is_symlink())
        for name in sorted(names):
            visited += 1
            if visited > 10000 or time.monotonic() - started > 5:
                incomplete = True
                break
            if name not in {'package-lock.json', 'requirements.txt'}:
                continue
            path = Path(directory, name)
            try:
                if path.is_symlink() or path.stat().st_size > 12*1024*1024 or len(files) >= 20:
                    incomplete = True
                    continue
                text = path.read_text(encoding='utf-8')
                source = path.relative_to(root).as_posix()
                files.append(source)
                if name == 'requirements.txt':
                    if re.search(r'(?m)^\s*(?:--(?:extra-)?index-url|--find-links|-r\s)', text):
                        incomplete = True
                        continue
                    for line in text.splitlines():
                        match = re.match(r'^\s*([A-Za-z0-9_.-]+)(?:\[[^\]]+\])?==([A-Za-z0-9.+_-]+)(?:\s*(?:#|;|--hash=).*)?\s*$', line)
                        if match:
                            add('PyPI', *match.groups(), source)
                        elif line.strip() and not line.lstrip().startswith('#'):
                            incomplete = True
                else:
                    lock = json.loads(text)
                    if not isinstance(lock, dict):
                        incomplete = True
                        continue
                    if not isinstance(lock.get('packages'), dict):
                        incomplete = True
                        continue
                    for key, value in lock['packages'].items():
                        if not key or not isinstance(value, dict) or value.get('link'):
                            continue
                        resolved = urlparse(value.get('resolved', ''))
                        if resolved.scheme != 'https' or resolved.hostname != 'registry.npmjs.org' or value.get('private'):
                            incomplete = True
                            continue
                        package_name = value.get('name') or key.rsplit('node_modules/', 1)[-1]
                        add('npm', package_name, value.get('version'), source)
            except (OSError, ValueError, TypeError, AttributeError):
                incomplete = True
        if visited > 10000 or time.monotonic() - started > 5:
            break
    items = list(packages.values())
    return {'packages': items, 'files': files, 'incomplete': incomplete,
            'fingerprint': hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest()}


def query_osv(payload, timeout):
    request = Request('https://api.osv.dev/v1/querybatch', data=json.dumps(payload).encode(),
                      headers={'Content-Type': 'application/json', 'User-Agent': 'Open-Kritt-local-audit/1'})
    with urlopen(request, timeout=timeout) as response:
        body = response.read(2*1024*1024+1)
        if len(body) > 2*1024*1024:
            raise ValueError('OSV response exceeds limit')
        return json.loads(body)


def audit_dependencies(root, query=query_osv, inventory=None):
    inventory = inventory or dependency_inventory(Path(root))
    report = {'status': 'partial' if inventory['incomplete'] else 'completed', 'checked_packages': 0,
              'detected_packages': len(inventory['packages']), 'files': inventory['files'], 'findings': [],
              'checked_at': time.time(), 'limitations': ['תמיכה ב־package-lock בגרסה 2/3 וב־requirements.txt עם גרסאות מדויקות בלבד. התאמה למאגר אינה הוכחה שהחולשה ניתנת לניצול בפרויקט.']}
    report['fingerprint'] = inventory['fingerprint']
    if not inventory['packages']:
        report['status'] = 'no_supported_packages'
        return report
    started = time.monotonic()
    try:
        for offset in range(0, len(inventory['packages']), 100):
            remaining = 25-(time.monotonic()-started)
            if remaining <= 0:
                report['status'] = 'partial'
                break
            batch = inventory['packages'][offset:offset+100]
            payload = {'queries': [{'package': {'name': p['name'], 'ecosystem': p['ecosystem']}, 'version': p['version']} for p in batch]}
            response = query(payload, min(8, remaining))
            if not isinstance(response, dict):
                raise ValueError('Invalid OSV response')
            results = response.get('results', [])
            if not isinstance(results, list) or len(results) != len(batch):
                raise ValueError('Incomplete OSV response')
            for package, result in zip(batch, results, strict=False):
                if not isinstance(result, dict):
                    raise ValueError('Invalid package response')
                report['checked_packages'] += 1
                if result.get('next_page_token'):
                    report['status'] = 'partial'
                vulnerabilities = result.get('vulns', [])
                if not isinstance(vulnerabilities, list):
                    raise ValueError('Invalid vulnerability response')
                ids = [v['id'] for v in vulnerabilities if isinstance(v, dict) and isinstance(v.get('id'), str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,150}', v['id'])]
                if ids:
                    report['findings'].append({**package, 'ids': ids[:100], 'verified': False})
                    if len(ids) > 100:
                        report['status'] = 'partial'
    except (OSError, ValueError, TypeError):
        report['status'] = 'partial' if report['checked_packages'] else 'unavailable'
        report['limitations'].append('החיבור למאגר נכשל או נחסם; אין לראות בכך בדיקה נקייה.')
    return report
