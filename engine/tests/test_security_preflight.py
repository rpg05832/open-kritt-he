from open_kritt_engine.security_preflight import inspect_repository, write_preflight


def test_redacts_secret_values_and_never_follows_links(tmp_path):
    secret = 'ghp_'+'x'*36
    (tmp_path/'app.js').write_text('const token="'+secret+'"; eval(input);', encoding='utf8')
    (tmp_path/'node_modules').mkdir()
    (tmp_path/'node_modules'/'skip.js').write_text('eval(x)')
    report = inspect_repository(tmp_path)
    assert report['files_checked'] == 1
    assert len(report['candidates']) == 2
    assert secret not in str(report)
    assert all(not item['verified'] for item in report['candidates'])

def test_inventory_bounds_and_ast_check(tmp_path):
    (tmp_path/'a.py').write_text('import subprocess\nsubprocess.run(x, shell=True)')
    (tmp_path/'b.js').write_text('eval(x)')
    report = inspect_repository(tmp_path, max_files=1)
    assert report['files_seen'] == 1
    assert report['limitations']
    assert any(item['rule'] == 'python-shell' for item in report['candidates'])


def test_semgrep_cache_invalidated_when_code_changes(tmp_path, monkeypatch):
    source = tmp_path/'source'
    source.mkdir()
    (source/'a.js').write_text('eval(input)')
    monkeypatch.setenv('ENGINE_DATA_DIR', str(tmp_path/'reports'))
    calls = []
    def fake_tool(root):
        calls.append(root)
        return {'status': 'completed', 'candidates': [], 'files_checked': 1}
    monkeypatch.setattr('open_kritt_engine.semgrep_checks.run_semgrep', fake_tool)
    write_preflight(source, 123)
    assert write_preflight(source, 123)['semgrep']['reused']
    assert len(calls) == 1
    (source/'a.js').write_text('console.log("fixed")')
    assert not write_preflight(source, 123)['semgrep'].get('reused')
    assert len(calls) == 2


def test_maps_go_and_java_manifests(tmp_path):
    (tmp_path/'go.mod').write_text('module example.com/test')
    (tmp_path/'pom.xml').write_text('<project/>')
    report = inspect_repository(tmp_path)
    assert set(report['manifests']) == {'go.mod', 'pom.xml'}
