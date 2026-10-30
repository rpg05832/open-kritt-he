import json

from open_kritt_engine.incremental_review import prepare_incremental_review
from open_kritt_engine.security_io import atomic_json


def scan(scan_id, mode='full', baseline=None):
    return {'id': scan_id, 'repo_full': 'example', 'repo_kind': 'local',
            'configuration': {'scan_mode': mode, 'incremental_baseline_id': baseline}}


def test_changes_and_deletions_are_compared_to_pinned_baseline(tmp_path, monkeypatch):
    monkeypatch.setenv('ENGINE_DATA_DIR', str(tmp_path/'data'))
    source = tmp_path/'source'
    source.mkdir()
    (source/'a.py').write_text('before')
    (source/'deleted.py').write_text('old')
    prepare_incremental_review(source, scan(1))
    (source/'a.py').write_text('after')
    (source/'deleted.py').unlink()
    (source/'new.py').write_text('new')
    report = prepare_incremental_review(source, scan(2, 'changes', '1'))
    assert report['effective_mode'] == 'changes'
    assert report['modified'] == ['a.py']
    assert report['added'] == ['new.py']
    assert report['deleted'] == ['deleted.py']
    assert 'before' not in json.dumps(report)


def test_missing_or_wrong_repository_baseline_falls_back_to_full(tmp_path, monkeypatch):
    monkeypatch.setenv('ENGINE_DATA_DIR', str(tmp_path/'data'))
    (tmp_path/'a.py').write_text('code')
    assert prepare_incremental_review(tmp_path, scan(2, 'changes', '99'))['effective_mode'] == 'full'
    prepare_incremental_review(tmp_path, scan(1))
    other = scan(3, 'changes', '1')
    other['repo_full'] = 'different'
    assert prepare_incremental_review(tmp_path, other)['effective_mode'] == 'full'


def test_generated_reports_do_not_follow_repository_symlinks(tmp_path):
    victim = tmp_path/'outside.txt'
    victim.write_text('untouched')
    target = tmp_path/'.open-kritt-changes.json'
    target.symlink_to(victim)
    atomic_json(target, {'safe': True})
    assert victim.read_text() == 'untouched'
    assert not target.is_symlink()


def test_primary_snapshot_with_extra_repositories_falls_back_to_full(tmp_path, monkeypatch):
    monkeypatch.setenv('ENGINE_DATA_DIR', str(tmp_path/'data'))
    source = tmp_path/'source'
    source.mkdir()
    output = tmp_path/'output'
    output.mkdir()
    first = scan(1)
    first['dependencies_detail'] = [{'kind': 'local', 'repo_full': 'dependency'}]
    prepare_incremental_review(source, first, output)
    second = {**first, 'id': 2, 'configuration': {'scan_mode': 'changes', 'incremental_baseline_id': '1'}}
    assert prepare_incremental_review(source, second, output)['effective_mode'] == 'full'
