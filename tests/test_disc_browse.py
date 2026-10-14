"""Disc browsing stays read-only, scoped to a catalog disc, and paginated."""
import json
import unittest
import test_workbench as fixture

class DiscBrowseTests(unittest.TestCase):
    setUp=fixture.WorkbenchTests.setUp
    close_server=fixture.WorkbenchTests.close_server
    request=fixture.WorkbenchTests.request

    def seed(self):
        root=self.base/'archive';root.mkdir();discs=[]
        for i in range(1,26):
            discs.append({'disc_id':f'BD-P-{i:04}','disc_index':i,'archive_set_id':'DEMO','category':'I','position':i,'disc_count':25,'volume_label':f'PHOTO-{i}', 'burn_date':'2026-10-10T12:00:00Z','status':'VERIFIED' if i%2 else 'BURNED_UNVERIFIED','stage':{'receipt':{'files':[{'path':f'data/2025-04-{i:02}_Travel/IMG_{i:04}.CR2','bytes':i*1000,'mtime':'2025-04-01T00:00:00Z'}]}}})
        data={'schema_version':1,'sets':[{'archive_set_id':'DEMO','summary':'Travel camera archive','summary_details':{'camera':'Test Camera','date_range':'2025-04-01 .. 2025-04-25'}}],'discs':discs}
        p=root/'catalog.json';p.write_text(json.dumps(data),encoding='utf-8');return p

    def test_disc_index_paginated_and_searches_summary_dates_filenames(self):
        p=self.seed();before=p.read_bytes()
        status,r,_=self.request('/api/discs?page=2&page_size=10')
        self.assertEqual(status,200,r);self.assertEqual(r['total'],25);self.assertEqual(len(r['items']),10)
        self.assertEqual(r['items'][0]['disc_id'],'BD-P-0011')
        for term in ('IMG_0023','PHOTO-23','2025-04-23'):
            _,r,_=self.request('/api/discs?q='+term);self.assertEqual([x['disc_id'] for x in r['items']],['BD-P-0023'])
        _,r,_=self.request('/api/discs?q=Travel');self.assertEqual(r['total'],25)
        self.assertEqual(p.read_bytes(),before);self.assertEqual(self.calls,[])

    def test_status_category_and_content_date_filters(self):
        self.seed();_,r,_=self.request('/api/discs?status=VERIFIED&category=I&date_kind=content&date_from=2025-04-21&date_to=2025-04-25')
        self.assertEqual([d['disc_id'] for d in r['items']],['BD-P-0021','BD-P-0023','BD-P-0025'])
        _,r,_=self.request('/api/discs?category=III');self.assertEqual(r['total'],0)
        _,r,_=self.request('/api/discs?date_kind=burn&date_from=2026-10-11');self.assertEqual(r['total'],0)

    def test_content_scoped_to_selected_disc_and_keeps_set_summary_distinct(self):
        self.seed();status,r,_=self.request('/api/discs/BD-P-0004/contents')
        self.assertEqual(status,200,r);self.assertEqual(r['total'],1)
        self.assertEqual(r['files'][0]['path'],'data/2025-04-04_Travel/IMG_0004.CR2')
        self.assertEqual(r['source'],'catalog_receipt');self.assertEqual(r['archive_summary'],'Travel camera archive')
        self.assertEqual(r['scope'],'disc');self.assertEqual(r['metadata_scope'],'archive_set')
        self.assertEqual(self.request('/api/discs/BD-P-9999/contents')[0],404)

    def test_file_filter_empty_means_no_matches_not_unknown_disc(self):
        self.seed();_,r,_=self.request('/api/discs/BD-P-0004/contents?q=IMG_0005')
        self.assertEqual(r['total'],0);self.assertEqual(r['indexed_files'],1)

    def test_missing_index_is_explicit_not_claimed_empty_disc(self):
        p=self.seed();j=json.loads(p.read_text());j['discs'][0]['stage']={};p.write_text(json.dumps(j))
        _,r,_=self.request('/api/discs/BD-P-0001/contents')
        self.assertEqual(r['source'],'unavailable');self.assertIsNone(r['indexed_files'])
        self.assertTrue(r['warnings'])

    def test_invalid_pagination_and_date_are_rejected(self):
        self.seed()
        for query in ('page=0','page_size=10000','date_from=bad','date_from=2025-10-11&date_to=2025-10-01','sort=DROP','status=unknown'):
            self.assertEqual(self.request('/api/discs?'+query)[0],400,query)
        self.assertEqual(self.request('/api/discs/..%2Fsecret/contents')[0],404)

    def test_new_ui_has_green_verified_exact_status_and_bounded_layout(self):
        p=fixture.ROOT/'ui/src/DiscLibrary.tsx';self.assertTrue(p.is_file())
        text=p.read_text(encoding='utf-8');css=(fixture.ROOT/'ui/src/styles.css').read_text(encoding='utf-8')
        self.assertIn("status==='VERIFIED'",text)
        for feature in ('disc-page','disc-filter-status','disc-query','disc-tab-content','content-query','date_from'):
            self.assertIn(feature,text)
        self.assertIn('.state-tag.verified',css);self.assertIn('.library-workspace',css)
