"""Public catalog localization tests use synthetic metadata and a loopback server."""
import hashlib
import importlib.util
import json
import pathlib
import re
import tempfile
import threading
import unittest
import urllib.request
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('catalog_locale_target', ROOT / 'catalog/catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class CatalogLocaleTests(unittest.TestCase):
    def setUp(self):
        work = ROOT / 'work/catalog-locale-tests'
        work.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=work)
        self.addCleanup(self.tmp.cleanup)
        self.db = pathlib.Path(self.tmp.name) / 'catalog.sqlite'
        source = pathlib.Path(self.tmp.name) / 'catalog.json'
        data = json.loads((ROOT / 'examples/catalog.example.json').read_text(encoding='utf-8'))
        data['sets'][0]['summary'] = '<script>do not execute</script> 原始照片'
        data['discs'][0]['location'] = '状态 <rack>'
        data['disc_aliases'] = [{'old_id': 'OLD-0012', 'new_id': 'BD-B-0012'}]
        source.write_text(json.dumps(data), encoding='utf-8')
        catalog.sync(source, self.db)
        self.before = hashlib.sha256(self.db.read_bytes()).hexdigest()
        self.server = catalog.ThreadingHTTPServer(('127.0.0.1', 0), catalog.make_handler(self.db))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.base = f'http://127.0.0.1:{self.server.server_port}'

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.assertEqual(hashlib.sha256(self.db.read_bytes()).hexdigest(), self.before,
                         'rendering must not mutate the live catalog snapshot')

    def get(self, path):
        response = urllib.request.urlopen(self.base + path)
        return response, response.read().decode('utf-8')

    def test_default_english_metadata_is_read_only_and_user_data_is_not_translated(self):
        response, body = self.get('/disc/BD-B-0012')
        self.assertIn('<html lang="en">', body)
        self.assertIn('<dt>Disc ID</dt>', body)
        self.assertIn('<dt>Physical location</dt>', body)
        self.assertIn('Read-only catalog', body)
        self.assertIn('<dd>状态 &lt;rack&gt;</dd>', body)
        self.assertIn('<dd>PLANNED</dd>', body)
        self.assertNotIn('<script>', body)
        self.assertIn("default-src 'none'", response.headers['Content-Security-Policy'])

    def test_chinese_switch_retains_current_disc_path_and_explicit_locale(self):
        _, body = self.get('/disc/BD-B-0012?lang=zh-CN')
        self.assertIn('<html lang="zh-CN">', body)
        self.assertIn('<dt>盘号</dt>', body)
        self.assertIn('href="/disc/BD-B-0012?lang=en"', body)
        self.assertIn('href="/disc/BD-B-0012?lang=zh-CN"', body)
        self.assertIn('href="/ids?lang=zh-CN"', body)
        self.assertIn('未记录', body)

    def test_navigation_keeps_language_and_nfc_identifiers_stay_stable(self):
        _, home = self.get('/?lang=zh-CN')
        self.assertIn('href="/set/IPHONE-2019-01?lang=zh-CN"', home)
        _, archive = self.get('/set/IPHONE-2019-01?lang=zh-CN')
        self.assertIn('href="/disc/BD-B-0012?lang=zh-CN"', archive)
        _, disc = self.get('/disc/BD-B-0012?lang=en')
        self.assertIn('http://archive.home:8765/disc/BD-B-0012', disc)

    def test_alias_redirect_retains_explicit_language_without_changing_default_url(self):
        response, _ = self.get('/disc/OLD-0012?lang=zh-CN')
        self.assertEqual(response.url, self.base + '/disc/BD-B-0012?lang=zh-CN')
        response, _ = self.get('/disc/OLD-0012')
        self.assertEqual(response.url, self.base + '/disc/BD-B-0012')

    def test_unsupported_language_falls_back_without_reflecting_html(self):
        _, body = self.get('/?lang=%3Cscript%3E')
        self.assertIn('<html lang="en">', body)
        self.assertIn('Cold archive catalog', body)
        self.assertIn('&lt;script&gt;do not execute&lt;/script&gt;', body)
        self.assertNotIn('<script>', body)

    def test_served_catalog_uses_ksp_mission_design_without_external_assets(self):
        _, body = self.get('/disc/BD-B-0012?lang=en')
        css = re.search(r'<style>(.*?)</style>', body, re.S).group(1)
        tokens = dict(re.findall(r'(--[a-z-]+)\s*:\s*([^;{}]+)', css))
        expected = {
            '--bg': '#020408', '--bg-soft': '#07101A', '--panel-strong': '#0A1420',
            '--text': '#F2F6FB', '--muted': '#8290A3', '--cyan': '#00A8E0',
            '--blue': '#005288', '--amber': '#F2A900', '--danger': '#E8312A',
            '--success': '#39D98A',
        }
        for name, value in expected.items():
            self.assertEqual(tokens.get(name, '').strip().upper(), value, name)
        self.assertEqual(re.sub(r'\s+', '', tokens['--divider']), 'rgba(255,255,255,0.14)')
        self.assertRegex(css, r'color-scheme:\s*dark')
        self.assertIn('class="mission-nav"', body)
        self.assertIn('var(--font-mono)', css)
        self.assertNotIn('fonts.googleapis.com', body)
        self.assertNotIn('url(http', css)
    def test_offline_fonts_are_served_only_from_the_explicit_six_file_allowlist(self):
        response, body = self.get('/?lang=en')
        self.assertIn('@font-face', body)
        self.assertIn("font-src 'self'", response.headers['Content-Security-Policy'])
        allowed = (
            'barlow-condensed-400.ttf', 'barlow-condensed-600.ttf',
            'ibm-plex-sans-400.ttf', 'ibm-plex-sans-600.ttf',
            'ibm-plex-mono-400.ttf', 'ibm-plex-mono-600.ttf',
        )
        for name in allowed:
            with self.subTest(font=name):
                try:
                    font = urllib.request.urlopen(self.base + '/assets/fonts/' + name)
                except urllib.error.HTTPError as error:
                    self.fail(f'Bundled font route unavailable: {name}: {error.code}')
                self.assertEqual(font.headers['Content-Type'], 'font/ttf')
                self.assertEqual(font.headers['X-Content-Type-Options'], 'nosniff')
                self.assertEqual(font.read(), (ROOT / 'assets/fonts' / name).read_bytes())
        for path in (
            '/assets/fonts/not-a-font.ttf', '/assets/fonts/ibm-plex-sans-OFL.txt',
            '/assets/fonts/%2e%2e/%2e%2e/catalog/catalog.py',
            '/assets/fonts/..%2f..%2fcatalog%2fcatalog.py',
            '/assets/fonts/%252e%252e/catalog.py', '/assets/catalog.sqlite',
        ):
            with self.subTest(rejected=path):
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(self.base + path)
                self.assertEqual(error.exception.code, 404)
    def test_volume_index_pages_are_bilingual_and_preserve_machine_state(self):
        for path in ('/ids', '/deleted', '/volume/IPHONE-2019-01-V0001'):
            with self.subTest(path=path):
                _, en = self.get(path + '?lang=en')
                _, zh = self.get(path + '?lang=zh-CN')
                self.assertIn('<html lang="en">', en)
                self.assertIn('<html lang="zh-CN">', zh)
                self.assertIn('IDs &amp; labels', en)
                self.assertIn('编号与卷标', zh)


if __name__ == '__main__':
    unittest.main()
