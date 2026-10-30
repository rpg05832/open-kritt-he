import json
import shutil
from types import SimpleNamespace

import pytest

from open_kritt_engine.semgrep_checks import run_semgrep


def test_missing_tool_is_explicit(monkeypatch, tmp_path):
    monkeypatch.setattr('shutil.which', lambda _: None)
    assert run_semgrep(tmp_path)['status'] == 'unavailable'


def test_never_persists_matched_source(monkeypatch, tmp_path):
    monkeypatch.setattr('shutil.which', lambda _: '/usr/bin/semgrep')
    payload = {'results': [{'check_id': 'test', 'path': str(tmp_path/'a.py'),
               'start': {'line': 3}, 'extra': {'message': 'check', 'lines': 'SECRET'}}],
               'paths': {'scanned': ['a.py']}, 'errors': []}
    def fake_run(command, **kwargs):
        assert '--jobs=1' in command and '--metrics=off' in command
        assert kwargs['timeout'] == 60
        return SimpleNamespace(returncode=0, stdout=json.dumps(payload))
    monkeypatch.setattr('subprocess.run', fake_run)
    report = run_semgrep(tmp_path)
    assert report['status'] == 'completed'
    assert report['candidates'][0]['file'] == 'a.py'
    assert 'SECRET' not in str(report)


@pytest.mark.skipif(not shutil.which('semgrep'), reason='Semgrep not installed')
def test_real_semgrep_rule(tmp_path):
    (tmp_path / 'test.js').write_text('eval(userInput);\n')
    report = run_semgrep(tmp_path)
    assert report['status'] == 'completed', report
    assert any('javascript-dynamic-eval' in f['rule'] for f in report['candidates'])
