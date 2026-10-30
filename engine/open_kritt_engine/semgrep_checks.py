"""Offline Semgrep adapter: local rules, bounded execution, no source in reports."""
import json
import os
import shutil
import subprocess
from pathlib import Path


def run_semgrep(root, timeout=60):
    binary = shutil.which('semgrep')
    if not binary:
        return {'status': 'unavailable', 'reason': 'Semgrep אינו מותקן', 'candidates': []}
    rules = Path(__file__).with_name('security_rules.json')
    command = [binary, 'scan', '--config', str(rules), '--json', '--metrics=off',
               '--disable-version-check', '--jobs=1', '--max-memory=512', '--timeout=5',
               '--max-target-bytes=524288', '--no-git-ignore', str(root)]
    for directory in ('.git', 'node_modules', '.venv', 'venv', 'dist', 'build', '.next'):
        command.extend(['--exclude', directory])
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                                env={**os.environ, 'SEMGREP_SEND_METRICS': 'off'})
        if result.returncode not in (0, 1):
            return {'status': 'failed', 'reason': 'הכלי לא סיים בהצלחה', 'candidates': []}
        payload = json.loads(result.stdout)
        candidates = []
        base = Path(root).resolve()
        for item in payload.get('results', [])[:200]:
            path = Path(item.get('path', ''))
            if not path.is_absolute():
                path = Path.cwd() / path
            try:
                relative = path.resolve().relative_to(base).as_posix()
            except ValueError:
                continue
            candidates.append({'rule': item.get('check_id'), 'file': relative,
                               'line': item.get('start', {}).get('line'),
                               'explanation': item.get('extra', {}).get('message', ''),
                               'verified': False})
        return {'status': 'partial' if payload.get('errors') else 'completed',
                'rule_count': len(json.loads(rules.read_text(encoding='utf-8'))['rules']), 'error_count': len(payload.get('errors', [])),
                'files_checked': len(payload.get('paths', {}).get('scanned', [])),
                'candidates': candidates}
    except subprocess.TimeoutExpired:
        return {'status': 'timeout', 'reason': 'הכלי הגיע למגבלת הזמן', 'candidates': []}
    except (OSError, ValueError):
        return {'status': 'failed', 'reason': 'לא ניתן לקרוא את תוצאות הכלי', 'candidates': []}
