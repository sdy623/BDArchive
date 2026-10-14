"""Loopback bridge tests: isolated config, mock processes, real preview only."""
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGET = ROOT / 'catalog/workbench.py'
bridge = None
if TARGET.exists():
    spec = importlib.util.spec_from_file_location('archive_workbench_test', TARGET)
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)


class BridgePresenceTests(unittest.TestCase):
    def test_bridge_exists(self):
        self.assertTrue(TARGET.exists(), 'The loopback web bridge is not implemented yet')


class FakeProcess:
    def __init__(self):
        self.returncode = None
    def poll(self):
        return self.returncode


@unittest.skipIf(bridge is None, 'Bridge implementation not yet present')
class WorkbenchTests(unittest.TestCase):
    def setUp(self):
        parent = ROOT / 'work/web-bridge-tests'
        parent.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.tmp.cleanup)
        self.base = pathlib.Path(self.tmp.name)
        self.config_path = self.base / 'config.json'
        self.config = json.loads((ROOT / 'archive.config.example.json').read_text(encoding='utf-8'))
        self.config['archive_root'] = './archive'
        self.config['private_secret'] = 'not-in-bootstrap'
        self.config_path.write_text(json.dumps(self.config), encoding='utf-8')
        self.ui = self.base / 'ui'
        self.ui.mkdir()
        (self.ui / 'index.html').write_text('<html>synthetic UI</html>', encoding='utf-8')
        (self.base / 'outside.txt').write_text('outside', encoding='utf-8')
        self.calls = []
        self.processes = []
        def launch(args, **kwargs):
            self.calls.append((args, kwargs))
            process = FakeProcess()
            self.processes.append(process)
            return process
        self.manager = bridge.JobManager(self.config_path, self.ui, pwsh='pwsh', launcher=launch)
        self.server = bridge.make_server(self.manager, port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f'http://127.0.0.1:{self.server.server_port}'
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.manager.close()

    def request(self, path, payload=None, headers=None, method=None):
        h = {'Origin': self.origin, 'X-Archive-Token': self.manager.token}
        if headers:
            h.update(headers)
        body = None if payload is None else json.dumps(payload).encode('utf-8')
        if body is not None:
            h['Content-Type'] = 'application/json'
        req = urllib.request.Request(self.origin + path, data=body, headers=h, method=method)
        try:
            response = urllib.request.urlopen(req)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            data = response.read()
            return response.status, (json.loads(data) if response.headers.get_content_type() == 'application/json' else data), response.headers

    def test_bootstrap_is_sanitized_and_inventory_is_real_worker_job(self):
        status, data, _ = self.request('/api/bootstrap')
        self.assertEqual(status, 200)
        self.assertEqual(data['token'], self.manager.token)
        self.assertNotIn('private_secret', data['config'])
        self.assertEqual(data['catalog'], {'discs': [], 'sets': []})
        self.assertEqual(data['devices'], [])
        self.assertEqual(data['inventory_status']['devices']['state'], 'RUNNING')
        self.assertTrue(data['capabilities']['physical_burn'])
        self.assertFalse((self.base / 'archive').exists())
        commands = [json.loads(pathlib.Path(args[-1]).read_text(encoding='utf-8'))['command'] for args, _ in self.calls]
        self.assertEqual(set(commands), {'devices', 'tools'})

    def test_desktop_shutdown_rejects_new_work_without_starting_a_process(self):
        self.manager.closing = True
        status, body, _ = self.request('/api/jobs', {'command':'prepare','parameters':{}})
        self.assertEqual(status,409)
        self.assertEqual(self.calls,[])

    def test_preview_defaults_and_paths_remain_literal_data(self):
        source = "D:\\Synthetic 用户\\RAW & $(touch NEVER); photo's"
        status, job, _ = self.request('/api/jobs', {'command': 'prepare', 'parameters': {'Source': source, 'SetId': 'DEMO-01', 'Scenario': 'photo'}})
        self.assertEqual(status, 202)
        args, kwargs = self.calls[-1]
        self.assertIsInstance(args, list)
        self.assertFalse(kwargs.get('shell', False))
        self.assertNotIn(source, args)
        request = json.loads(pathlib.Path(args[-1]).read_text(encoding='utf-8'))
        self.assertEqual(request['parameters']['Source'], source)
        self.assertIs(request['parameters']['Execute'], False)
        self.assertEqual(request['parameters']['Config'], str(self.config_path.resolve()))
        self.assertNotIn('-Command', args)
        self.assertEqual(job['state'], 'RUNNING')

    def test_arbitrary_commands_and_parameters_are_rejected(self):
        for command in ('delete-source', 'Invoke-Expression', 'prepare; exit', 'mount'):
            self.assertEqual(self.request('/api/jobs', {'command': command, 'parameters': {}})[0], 400)
        for parameter in ('Config', 'RequestPath', 'ConfirmationMode', 'BurnConfirmed', 'DeleteSourceConfirmed', 'config'):
            self.assertEqual(self.request('/api/jobs', {'command': 'prepare', 'parameters': {parameter: 'bad'}})[0], 400)
        self.assertEqual(len(self.calls), 0)

    def test_string_booleans_and_unknown_top_level_fields_rejected(self):
        self.assertEqual(self.request('/api/jobs', {'command': 'prepare', 'parameters': {'Execute': 'false'}})[0], 400)
        self.assertEqual(self.request('/api/jobs', {'command': 'prepare', 'parameters': {}, 'script': 'bad'})[0], 400)

    def test_mutation_auth_host_origin_and_cross_site_guards(self):
        payload = {'command': 'prepare', 'parameters': {}}
        for headers in ({'X-Archive-Token': ''}, {'Origin': 'https://evil.invalid'}, {'Host': 'evil.invalid'}, {'Sec-Fetch-Site': 'cross-site'}):
            self.assertEqual(self.request('/api/jobs', payload, headers)[0], 403)
        self.assertEqual(self.request('/api/bootstrap', headers={'Host': 'evil.invalid'})[0], 403)
        self.assertEqual(self.request('/api/bootstrap', headers={'Origin': 'https://evil.invalid'})[0], 403)
        self.assertEqual(len(self.calls), 0)

    def test_missing_origin_is_denied_for_post(self):
        req = urllib.request.Request(self.origin + '/api/jobs', data=b'{"command":"prepare","parameters":{}}', headers={'Content-Type': 'application/json', 'X-Archive-Token': self.manager.token})
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(req)
        self.assertEqual(error.exception.code, 403)

    def test_physical_burn_without_fresh_review_is_blocked_even_with_phrase(self):
        body = {'command': 'burn', 'parameters': {'DiscId': 'BD-P-0001', 'Execute': True}, 'confirmation': 'BURN BD-P-0001'}
        status, result, _ = self.request('/api/jobs', body)
        self.assertEqual(status, 409)
        self.assertEqual(result['code'], 'burn_review_required')
        self.assertEqual(len(self.calls), 0)
        self.assertEqual(self.request('/api/jobs', {'command': 'burn', 'parameters': {'DiscId': 'BD-P-0001'}})[0], 202)

    def make_review_fixture(self):
        archive = self.base / 'archive'
        archive.mkdir(exist_ok=True)
        disc = {'disc_id':'BD-P-0001','archive_set_id':'SYNTHETIC','stage':{'hash':'a'*64,'path':'D:/Synthetic/staging'}}
        (archive/'catalog.json').write_text(json.dumps({'discs':[disc],'sets':[]}), encoding='utf-8')
        for command in ('devices','tools'):
            j=self.manager.start({'command':command,'parameters':{}})
            self.manager.inventory[command]=j['id']
            path=pathlib.Path(self.calls[-1][0][-1])
            data=[{'drive':'X:','recorder_id':'SYNTHETIC','model':'FAKE','blank':True}] if command=='devices' else []
            pathlib.Path(str(path)+'.result.json').write_text(json.dumps({'status':'PASS','result':data}),encoding='utf-8')
            self.processes[-1].returncode=0
        params={'DiscId':'BD-P-0001','Drive':'X:','RecorderId':'SYNTHETIC','Backend':'ImgBurn'}
        status,review,_=self.request('/api/burn-review',params)
        self.assertEqual(status,200)
        return params,review

    def test_burn_review_exact_phrase_single_use_and_context(self):
        params,review=self.make_review_fixture()
        body={'command':'burn','parameters':{**params,'Execute':True},'review_id':review['review_id'],'confirmation':'BURN BD-P-0001'}
        self.assertEqual(self.request('/api/jobs',body)[0],202)
        request=json.loads(pathlib.Path(self.calls[-1][0][-1]).read_text(encoding='utf-8'))
        self.assertEqual(request['parameters']['ConfirmationMode'],'Typed')
        self.assertEqual(request['parameters']['ConfirmationContext']['manifest_sha256'],'a'*64)
        self.assertEqual(self.request('/api/jobs',body)[0],409)

    def test_burn_review_rejects_wrong_phrase_and_changed_drive(self):
        params,review=self.make_review_fixture()
        before=len(self.calls)
        body={'command':'burn','parameters':{**params,'Execute':True},'review_id':review['review_id'],'confirmation':'BURN BD-P-9999'}
        self.assertEqual(self.request('/api/jobs',body)[0],409)
        self.assertEqual(len(self.calls),before)
        _,review,_=self.request('/api/burn-review',params)
        body.update(review_id=review['review_id'],confirmation='BURN BD-P-0001')
        body['parameters']['Drive']='Y:'
        self.assertEqual(self.request('/api/jobs',body)[0],409)
        self.assertEqual(len(self.calls),before)

    def test_destructive_cleanup_is_not_exposed(self):
        for cmd in ('delete-source','delete-disc-record','delete-orphan-set','discard-unburned-plan'):
            self.assertEqual(self.request('/api/jobs',{'command':cmd,'parameters':{'Execute':True}})[0],400)
        self.assertEqual(len(self.calls),0)

    def test_cancel_writes_only_existing_cooperative_signal(self):
        _, job, _ = self.request('/api/jobs', {'command': 'prepare', 'parameters': {'Execute': True, 'Source': 'D:\\Synthetic'}})
        request_path = pathlib.Path(self.calls[-1][0][-1])
        status, cancelled, _ = self.request('/api/jobs/' + job['id'] + '/cancel', {})
        self.assertEqual(status, 202)
        self.assertEqual(cancelled['state'], 'CANCEL_REQUESTED')
        self.assertTrue(pathlib.Path(str(request_path) + '.cancel').is_file())
        self.assertNotEqual(cancelled['state'], 'CANCELLED')
        _, burn, _ = self.request('/api/jobs', {'command': 'burn', 'parameters': {'Simulate': True, 'Execute': True}})
        self.assertEqual(self.request('/api/jobs/' + burn['id'] + '/cancel', {})[0], 409)

    def test_result_progress_and_exit_code_are_observed_not_fabricated(self):
        _, job, _ = self.request('/api/jobs', {'command': 'prepare', 'parameters': {}})
        path = pathlib.Path(self.calls[-1][0][-1])
        pathlib.Path(str(path) + '.log').write_text('literal worker output\n', encoding='utf-8')
        pathlib.Path(str(path) + '.progress.json').write_text('{"message":"checking","metrics":{"bytes":19}}', encoding='utf-8')
        pathlib.Path(str(path) + '.result.json').write_text('{"status":"PASS","result":{"status":"DRY_RUN"}}', encoding='utf-8')
        self.processes[-1].returncode = 0
        _, detail, _ = self.request('/api/jobs/' + job['id'])
        self.assertEqual(detail['state'], 'DRY_RUN')
        self.assertEqual(detail['exit_code'], 0)
        self.assertEqual(detail['log'], pathlib.Path(str(path) + '.log').read_bytes().decode('utf-8'))
        self.assertEqual(detail['progress']['metrics']['bytes'], 19)
        self.assertEqual(self.request('/api/jobs/unknown')[0], 404)

    def test_asset_traversal_and_no_html_api_fallback(self):
        self.assertEqual(self.request('/')[0], 200)
        for path in ('/%2e%2e/outside.txt', '/%252e%252e/outside.txt', '/..%5coutside.txt', '/api/unknown', '/assets/no-file.js'):
            self.assertEqual(self.request(path)[0], 404)
        _, _, headers = self.request('/')
        self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
        self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')
        self.assertNotIn('Access-Control-Allow-Origin', headers)

    def test_body_size_limit(self):
        status, _, _ = self.request('/api/jobs', {'command': 'prepare', 'parameters': {'Source': 'x' * 70000}})
        self.assertEqual(status, 413)

    def test_settings_fixed_schema_atomic_and_safety_not_editable(self):
        status, data, _ = self.request('/api/config', {'config': {'planning': {'par2_percent': 5}, 'ui': {'language': 'zh-CN'}}})
        self.assertEqual(status, 200)
        self.assertEqual(data['config']['planning']['par2_percent'], 5)
        saved = json.loads(self.config_path.read_text(encoding='utf-8'))
        self.assertTrue(saved['safety']['default_dry_run'])
        self.assertEqual(saved['private_secret'], 'not-in-bootstrap')
        for config in ({'safety': {'default_dry_run': False}}, {'unknown': 'x'}, {'planning': {'par2_percent': -1}}, {'tools': {'python': ['bad']}}):
            self.assertEqual(self.request('/api/config', {'config': config})[0], 400)

    def test_settings_blocked_while_a_worker_is_active(self):
        self.request('/api/jobs', {'command': 'prepare', 'parameters': {}})
        self.assertEqual(self.request('/api/config', {'config': {'burn': {'speed': '6x'}}})[0], 409)

    @unittest.skipUnless(shutil.which('pwsh'), 'PowerShell 7 not available')
    def test_real_worker_preview_only_preserves_source_and_archive(self):
        source = self.base / 'Synthetic 用户 & RAW'
        source.mkdir()
        (source / 'photo.raw').write_bytes(b'unchanged')
        request = self.base / 'preview.request.json'
        request.write_text(json.dumps({'command': 'prepare', 'parameters': {'Config': str(self.config_path), 'Source': str(source), 'SetId': 'DEMO-01', 'Scenario': 'photo', 'Execute': False}}), encoding='utf-8')
        proc = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-File', str(ROOT / 'scripts/run-web-request.ps1'), '-RequestPath', str(request)], capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(pathlib.Path(str(request) + '.result.json').read_text(encoding='utf-8-sig'))
        self.assertEqual(result['result']['status'], 'DRY_RUN')
        self.assertEqual(result['result']['parameters']['Source'], str(source))
        self.assertFalse((self.base / 'archive').exists())
        self.assertEqual((source / 'photo.raw').read_bytes(), b'unchanged')


if __name__ == '__main__':
    unittest.main()