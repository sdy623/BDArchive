"""Existing-library connection: synthetic files only, never creates or syncs a catalog."""
from contextlib import closing
import json
import sqlite3
import unittest
import test_workbench as fixture

class LibraryTests(unittest.TestCase):
    setUp = fixture.WorkbenchTests.setUp
    close_server = fixture.WorkbenchTests.close_server
    request = fixture.WorkbenchTests.request

    def library(self, json_file=True, sql_file=True):
        root=self.base/'Existing 库 & spaces'; root.mkdir(exist_ok=True)
        if json_file:
            (root/'catalog.json').write_text(json.dumps({'schema_version':1,'catalog_id':'synthetic','sets':[{'archive_set_id':'DEMO'}], 'discs':[{'disc_id':'BD-P-0042','archive_set_id':'DEMO','status':'VERIFIED','stage':{'path':'synthetic stage','hash':'a'*64}}]}),encoding='utf-8')
        if sql_file:
            with closing(sqlite3.connect(root/'catalog.sqlite')) as con, con:
                con.executescript("CREATE TABLE discs(disc_id TEXT,archive_set_id TEXT,status TEXT);CREATE TABLE archive_sets(archive_set_id TEXT);INSERT INTO discs VALUES('BD-P-0042','DEMO','VERIFIED');INSERT INTO archive_sets VALUES('DEMO');")
        return root

    def test_connect_json_file_sets_root_and_sqlite_without_modifying_library(self):
        root=self.library(); before={p.name:p.read_bytes() for p in root.iterdir()}
        status,result,_=self.request('/api/library/connect',{'path':str(root/'catalog.json')})
        self.assertEqual(status,200,result)
        self.assertEqual(result['library']['mode'],'JSON')
        self.assertEqual(result['library']['sqlite_disc_count'],1)
        self.assertTrue(result['library']['index_matches'])
        saved=json.loads(self.config_path.read_text(encoding='utf-8'))
        self.assertEqual(saved['archive_root'],str(root))
        self.assertEqual(saved['catalog_path'],str(root/'catalog.sqlite'))
        self.assertEqual(saved['private_secret'],'not-in-bootstrap')
        self.assertEqual(before,{p.name:p.read_bytes() for p in root.iterdir()})
        self.assertEqual(self.manager.catalog()['discs'][0]['disc_id'],'BD-P-0042')
        self.assertEqual(fixture.bridge.JobManager(self.config_path).catalog(),self.manager.catalog())

    def test_preview_directory_is_read_only_and_reports_sources(self):
        root=self.library(); before=self.config_path.read_bytes()
        status,r,_=self.request('/api/library/preview',{'path':str(root)})
        self.assertEqual(status,200,r);self.assertEqual(r['library']['disc_count'],1)
        self.assertEqual(self.config_path.read_bytes(),before)
        self.assertEqual(self.calls,[])

    def test_select_sqlite_uses_complete_sibling_json_when_available(self):
        root=self.library()
        status,r,_=self.request('/api/library/connect',{'path':str(root/'catalog.sqlite')})
        self.assertEqual(status,200,r);self.assertEqual(r['library']['mode'],'JSON')
        self.assertIn('stage',self.manager.catalog()['discs'][0])

    def test_sqlite_only_is_readonly_and_blocks_worker_not_silent_init(self):
        root=self.library(json_file=False); before=(root/'catalog.sqlite').read_bytes()
        status,r,_=self.request('/api/library/connect',{'path':str(root/'catalog.sqlite')})
        self.assertEqual(status,200,r);self.assertEqual(r['library']['mode'],'SQLITE_READ_ONLY')
        self.assertEqual(self.manager.catalog()['discs'][0]['status'],'VERIFIED')
        for cmd in ('init','prepare','register','burn','set-counter','summary'):
            status,_,_=self.request('/api/jobs',{'command':cmd,'parameters':{'Execute':True}})
            self.assertEqual(status,409,cmd)
        self.assertEqual(self.calls,[])
        self.assertFalse((root/'catalog.json').exists())
        self.assertEqual((root/'catalog.sqlite').read_bytes(),before)

    def test_missing_or_corrupt_path_preserves_config_and_does_not_create(self):
        before=self.config_path.read_bytes();root=self.base/'Missing'
        status,_,_=self.request('/api/library/connect',{'path':str(root)})
        self.assertEqual(status,400);self.assertFalse(root.exists())
        root=self.library();(root/'catalog.json').write_text('broken',encoding='utf-8')
        status,_,_=self.request('/api/library/connect',{'path':str(root)})
        self.assertEqual(status,400)
        self.assertEqual(self.config_path.read_bytes(),before)

    def test_broken_current_catalog_does_not_hide_settings_or_session_token(self):
        root=self.library();(root/'catalog.json').write_text('broken')
        c=self.config.copy();c['archive_root']=str(root);self.config_path.write_text(json.dumps(c))
        status,r,_=self.request('/api/bootstrap')
        self.assertEqual(status,200,r);self.assertEqual(r['library']['mode'],'ERROR')
        self.assertIn('token',r);self.assertIn('archive_root',r['config'])

    def test_active_archive_job_blocks_switch_but_inventory_does_not(self):
        root=self.library();self.request('/api/bootstrap')
        status,r,_=self.request('/api/library/connect',{'path':str(root)})
        self.assertEqual(status,200,r)
        self.request('/api/jobs',{'command':'prepare','parameters':{}})
        self.assertEqual(self.request('/api/library/connect',{'path':str(root)})[0],409)

    def test_stale_index_is_reported_and_never_overwrites_json(self):
        root=self.library()
        with closing(sqlite3.connect(root/'catalog.sqlite')) as con, con:con.execute("UPDATE discs SET status='STAGED'")
        before=(root/'catalog.json').read_bytes()
        status,r,_=self.request('/api/library/connect',{'path':str(root)})
        self.assertEqual(status,200,r);self.assertFalse(r['library']['index_matches'])
        self.assertEqual(self.manager.catalog()['discs'][0]['status'],'VERIFIED')
        self.assertEqual(before,(root/'catalog.json').read_bytes())

    def test_library_endpoints_require_same_origin_session(self):
        root=self.library()
        for endpoint in ('preview','connect'):
            self.assertEqual(self.request('/api/library/'+endpoint,{'path':str(root)},headers={'X-Archive-Token':'wrong'})[0],403)

    def test_library_input_visible_on_discs_and_settings(self):
        app=(fixture.ROOT/'ui/src/App.tsx').read_text(encoding='utf-8')
        self.assertIn('function LibraryPanel',app)
        self.assertGreaterEqual(app.count('<LibraryPanel'),2)
        self.assertIn('/api/library/connect',app)
        self.assertIn('catalog.json / catalog.sqlite',app)
