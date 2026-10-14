import importlib.util
import json
import pathlib
import sqlite3
import tempfile
import threading
import unittest
import urllib.request
import urllib.error

ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('catalog',ROOT/'catalog'/'catalog.py')
catalog=importlib.util.module_from_spec(spec);spec.loader.exec_module(catalog)

class CatalogTests(unittest.TestCase):
    def setUp(self):
        work=ROOT/'work'/'catalog-tests'
        work.mkdir(parents=True,exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=work)
        assert pathlib.Path(self.tmp.name).resolve().parent == work.resolve()
        self.addCleanup(self.tmp.cleanup)
        self.db=pathlib.Path(self.tmp.name)/'metadata.sqlite'
        self.source=pathlib.Path(self.tmp.name)/'catalog.json'
        self.data=json.loads((ROOT/'examples'/'catalog.example.json').read_text())
        self.source.write_text(json.dumps(self.data),encoding='utf-8')
        catalog.sync(self.source,self.db)
    def test_snapshot_and_id(self):
        catalog.sync(self.source,self.db)
        self.assertEqual(len(catalog.rows(self.db)),1)
        self.assertEqual(catalog.rows(self.db)[0]['disc_id'],'BD-B-0012')
    def test_renamed_disc_and_set_old_urls_redirect_without_duplicate_rows(self):
        self.data['disc_aliases']=[{'old_id':'IPA-009','new_id':'BD-B-0012'}]
        self.data['set_aliases']=[{'old_id':'OLD-IPHONE','new_id':'IPHONE-2019-01'}]
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        self.assertEqual(len(catalog.rows(self.db)),1)
        server=catalog.ThreadingHTTPServer(('127.0.0.1',0),catalog.make_handler(self.db))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            base=f'http://127.0.0.1:{server.server_port}'
            for old,new in (('/disc/IPA-009','/disc/BD-B-0012'),('/set/OLD-IPHONE','/set/IPHONE-2019-01')):
                response=urllib.request.urlopen(base+old)
                self.assertEqual(response.url,base+new);self.assertEqual(response.status,200)
            self.assertNotIn('/disc/IPA-009',urllib.request.urlopen(base+'/ids').read().decode())
        finally:server.shutdown();server.server_close();thread.join()
    def test_bad_aliases_roll_back_snapshot(self):
        for aliases in (
            [{'old_id':'IPA-009','new_id':'MISSING-001'}],
            [{'old_id':'BD-B-0012','new_id':'BD-B-0012'}],
            [{'old_id':'../IPA-009','new_id':'BD-B-0012'}],
            [{'old_id':'IPA-009','new_id':'BD-B-0012'}]*2):
            self.data['disc_aliases']=aliases
            self.source.write_text(json.dumps(self.data),encoding='utf-8')
            with self.assertRaises(ValueError):catalog.sync(self.source,self.db)
            self.assertEqual(len(catalog.rows(self.db)),1)
            with catalog.connect(self.db,True) as con:
                self.assertEqual(con.execute('SELECT COUNT(*) FROM disc_aliases').fetchone()[0],0)
    def test_custom_prefix_deleted_record_and_restore(self):
        d=self.data['discs'][0];d['disc_id']='IPA-009';d['volume_label']='IPA-009';d['catalog_deleted']=True
        d['catalog_deleted_at']='2026-09-05T01:00:00Z';d['catalog_delete_reason']='Synthetic deletion'
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        self.assertEqual(catalog.rows(self.db),[])
        self.assertEqual(catalog.rows(self.db,True)[0]['disc_prefix'],'IPA')
        self.assertEqual(catalog.rows(self.db,True)[0]['disc_number'],9)
        d['catalog_deleted']=False
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        self.assertEqual(catalog.rows(self.db)[0]['disc_id'],'IPA-009')
    def test_deleted_http_route_and_volume_metadata_are_readable_and_escaped(self):
        d=self.data['discs'][0];d['catalog_deleted']=True
        d['authoring_metadata']={'values':{'publisher':'<script>metadata</script>'},'targets':{'publisher':'MANIFEST_ONLY_IN_UDF_MODE'}}
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        server=catalog.ThreadingHTTPServer(('127.0.0.1',0),catalog.make_handler(self.db))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            base=f'http://127.0.0.1:{server.server_port}'
            self.assertNotIn('/disc/BD-B-0012',urllib.request.urlopen(base+'/ids').read().decode())
            self.assertIn('/disc/BD-B-0012',urllib.request.urlopen(base+'/deleted').read().decode())
            content=urllib.request.urlopen(base+'/disc/BD-B-0012').read().decode()
            self.assertIn('&lt;script&gt;metadata&lt;/script&gt;',content);self.assertNotIn('<script>',content)
            self.assertIn('MANIFEST_ONLY_IN_UDF_MODE',content)
            self.assertIn('RECORD_DELETED',urllib.request.urlopen(base+'/set/IPHONE-2019-01').read().decode())
        finally:server.shutdown();server.server_close();thread.join()
    def test_transaction_rollback(self):
        self.data['discs'].append(self.data['discs'][0])
        self.source.write_text(json.dumps(self.data),encoding='utf-8')
        with self.assertRaises(sqlite3.IntegrityError):catalog.sync(self.source,self.db)
        self.assertEqual(len(catalog.rows(self.db)),1)
    def test_id_index_label_and_physical_serial(self):
        d=self.data['discs'][0]
        self.data['catalog_id']='synthetic-catalog'
        d.update(catalog_id='synthetic-catalog',disc_index=23,volume_id='TEST-V0001',
                 volume_label='BACKUP_0012',identity_origin='planned',
                 verification={'status':'PASS','simulation':False,'media':{'volume_serial':'1234ABCD'}})
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        row=catalog.rows(self.db)[0]
        self.assertEqual((row['disc_index'],row['volume_id'],row['volume_label'],row['filesystem_serial']),
                         (23,'TEST-V0001','BACKUP_0012','1234ABCD'))
        d['verification']['simulation']=True
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        self.assertIsNone(catalog.rows(self.db)[0]['filesystem_serial'])
    def test_legacy_schema_additive_migration_and_counter_recovery(self):
        with catalog.connect(self.db) as con:
            con.execute('DROP TABLE disc_identity');con.execute('DROP TABLE id_counters')
        self.data['sequences']['B']=0
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        with catalog.connect(self.db,True) as con:
            self.assertEqual(con.execute("SELECT next_number FROM id_counters WHERE prefix='B'").fetchone()[0],13)
        self.assertEqual(catalog.rows(self.db)[0]['volume_id'],'IPHONE-2019-01-V0001')
    def test_duplicate_label_rollback(self):
        d=self.data['discs'][0];d['volume_label']='SAME';d['disc_index']=1
        other=dict(d,disc_id='BD-B-0013',position=2,disc_index=2)
        self.data['discs'].append(other)
        self.source.write_text(json.dumps(self.data),encoding='utf-8')
        with self.assertRaises(sqlite3.IntegrityError):catalog.sync(self.source,self.db)
        self.assertEqual(catalog.rows(self.db)[0]['volume_label'],'BD-B-0012')
    def test_id_and_volume_http_routes_are_read_only(self):
        server=catalog.ThreadingHTTPServer(('127.0.0.1',0),catalog.make_handler(self.db))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            base=f'http://127.0.0.1:{server.server_port}'
            self.assertIn('BD-B-0013',urllib.request.urlopen(base+'/ids').read().decode())
            self.assertIn('Volume ID',urllib.request.urlopen(base+'/volume/IPHONE-2019-01-V0001').read().decode())
            with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(urllib.request.Request(base+'/ids',data=b'{}',method='POST'))
            self.assertEqual(e.exception.code,501)
        finally:server.shutdown();server.server_close();thread.join()
    def test_http_routes_escape_html_and_no_mutations(self):
        self.data['sets'][0]['summary']='<script>alert(1)</script>'
        self.data['sets'][0]['summary_details']={'device':'iPhone 13','encrypted':'YES','backup_folder_id':'***','second_copy':'<script>copy note</script>','password_storage':'password manager'}
        self.source.write_text(json.dumps(self.data),encoding='utf-8');catalog.sync(self.source,self.db)
        server=catalog.ThreadingHTTPServer(('127.0.0.1',0),catalog.make_handler(self.db))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            base=f'http://127.0.0.1:{server.server_port}'
            for path in ('/','/disc/BD-B-0012','/set/IPHONE-2019-01'):
                content=urllib.request.urlopen(base+path).read().decode()
                self.assertNotIn('<script>',content);self.assertIn('&lt;script&gt;',content)
                if path!='/':
                    self.assertIn('iPhone 13',content);self.assertIn('password manager',content)
            with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(base+'/disc/unknown')
            self.assertEqual(e.exception.code,404)
            with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(urllib.request.Request(base+'/',data=b'{}',method='POST'))
            self.assertEqual(e.exception.code,501)
        finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
