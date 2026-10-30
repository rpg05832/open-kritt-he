import json
import os

import pytest

from open_kritt_engine.dependency_audit import audit_dependencies, dependency_inventory


def test_only_pinned_versions_and_public_npm_registry(tmp_path):
    (tmp_path/'package-lock.json').write_text(json.dumps({'packages': {
        '': {'name': 'private-root', 'version': '1.0.0'},
        'node_modules/lodash': {'version': '4.17.20', 'resolved': 'https://registry.npmjs.org/lodash/-/lodash-4.17.20.tgz'},
        'node_modules/internal': {'version': '1.0.0', 'resolved': 'https://internal.example/internal.tgz'}
    }}))
    (tmp_path/'requirements.txt').write_text('flask==2.0.0\nrequests>=2\nsecret @ https://user:password@example.com/p.whl\n')
    report = dependency_inventory(tmp_path)
    assert {(p['ecosystem'], p['name'], p['version']) for p in report['packages']} == {('npm', 'lodash', '4.17.20'), ('PyPI', 'flask', '2.0.0')}
    assert 'password' not in str(report)


def test_partial_response_and_no_source_sent(tmp_path):
    (tmp_path/'requirements.txt').write_text('flask==2.0.0')
    def query(payload, timeout):
        assert payload == {'queries': [{'package': {'name': 'flask', 'ecosystem': 'PyPI'}, 'version': '2.0.0'}]}
        return {'results': [{'vulns': [{'id': 'GHSA-test'}], 'next_page_token': 'more'}]}
    report = audit_dependencies(tmp_path, query=query)
    assert report['status'] == 'partial'
    assert report['checked_packages'] == 1
    assert report['findings'][0]['ids'] == ['GHSA-test']


def test_network_failure_is_not_clean_result(tmp_path):
    (tmp_path/'requirements.txt').write_text('flask==2.0.0')
    def unavailable(*args):
        raise OSError('blocked')
    assert audit_dependencies(tmp_path, query=unavailable)['status'] == 'unavailable'


def test_invalid_manifest_or_api_payload_never_claims_clean_scan(tmp_path):
    (tmp_path/'package-lock.json').write_text('[]')
    assert dependency_inventory(tmp_path)['incomplete']
    (tmp_path/'requirements.txt').write_text('flask==2.0.0')
    assert audit_dependencies(tmp_path, query=lambda *args: [])['status'] == 'unavailable'


@pytest.mark.skipif(os.getenv('KRITT_OSV_LIVE_TEST') != '1', reason='Explicit live connectivity check only')
def test_live_osv_public_example(tmp_path):
    (tmp_path/'requirements.txt').write_text('jinja2==2.4.1')
    report = audit_dependencies(tmp_path)
    assert report['status'] == 'completed', report
    assert report['findings'], report
