"""Content-based comparison; keeps hashes, never copies source into reports."""
import hashlib
import json
import os
import time
from pathlib import Path

from .security_io import atomic_json

SKIP = {'.git', 'node_modules', '.venv', 'venv', 'dist', 'build', '.next', '__pycache__'}


def prepare_incremental_review(root, scan, output_root=None):
    root = Path(root)
    configuration = scan.get('configuration') or {}
    requested = 'changes' if configuration.get('scan_mode') == 'changes' else 'full'
    signature = json.dumps({'layout': 'primary' if output_root else 'expanded',
        **{key: scan.get(key) for key in ('repo_full', 'repo_kind', 'dependencies_detail', 'repo_scope', 'workflow_id')}}, sort_keys=True)
    files = {}
    complete = True
    started = time.monotonic()
    total_bytes = 0
    visited = 0
    for directory, dirs, names in os.walk(root, followlinks=False):
        if any(Path(directory, d).is_symlink() for d in dirs):
            complete = False
        dirs[:] = sorted(d for d in dirs if d not in SKIP and not Path(directory, d).is_symlink())
        for name in sorted(names):
            if name.startswith('.open-kritt-') or name in {'WORKSPACE.json', 'WORKSPACE.md'}:
                continue
            visited += 1
            if visited > 10000 or time.monotonic()-started > 10 or total_bytes > 256*1024*1024:
                complete = False
                break
            path = Path(directory, name)
            try:
                size = path.stat().st_size
                if path.is_symlink() or size > 4*1024*1024:
                    complete = False
                    continue
                content = path.read_bytes()
                total_bytes += len(content)
                files[path.relative_to(root).as_posix()] = hashlib.sha256(content).hexdigest()
            except OSError:
                complete = False
        if visited > 10000 or time.monotonic()-started > 10 or total_bytes > 256*1024*1024:
            break
    directory = Path(os.getenv('ENGINE_DATA_DIR', '/data')) / 'security-indexes'
    directory.mkdir(parents=True, exist_ok=True)
    report = {'requested_mode': requested, 'effective_mode': 'full', 'files_indexed': len(files),
              'inventory_complete': complete, 'added': [], 'modified': [], 'deleted': []}
    baseline = str(configuration.get('incremental_baseline_id') or '')
    if requested == 'changes':
        try:
            if output_root and (scan.get('dependencies_detail') or scan.get('dependencies')):
                raise ValueError('Dependency repositories are not included in the primary snapshot index')
            if not baseline.isdigit() or int(baseline) >= int(scan['id']):
                raise ValueError('Missing baseline')
            previous = json.loads((directory / f'scan-{int(baseline)}.json').read_text(encoding='utf-8'))
            if not complete or not previous.get('complete') or previous.get('signature') != signature:
                raise ValueError('Incompatible or incomplete baseline')
            old = previous['files']
            added = sorted(set(files)-set(old))
            modified = sorted(name for name in set(files)&set(old) if files[name] != old[name])
            deleted = sorted(set(old)-set(files))
            if len(added)+len(modified)+len(deleted) > 500:
                raise ValueError('Large change set')
            report.update(effective_mode='changes', baseline_scan_id=baseline,
                          added=added, modified=modified, deleted=deleted)
        except (OSError, ValueError, KeyError, TypeError):
            report['reason'] = 'אין בסיס השוואה מלא ותואם או שהשינוי גדול מדי; תבוצע בדיקה מלאה.'
    index = {'version': 1, 'signature': signature, 'complete': complete, 'files': files}
    atomic_json(directory / f"scan-{int(scan['id'])}.json", index)
    atomic_json(Path(output_root or root) / '.open-kritt-changes.json', report)
    return report
