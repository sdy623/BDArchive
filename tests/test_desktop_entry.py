"""Portable EXE startup must stay local, non-destructive and relocatable."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'catalog/desktop_entry.py'

class DesktopEntryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(TARGET.is_file(), 'Missing portable EXE entry point')
        spec = importlib.util.spec_from_file_location('bd_desktop_entry', TARGET)
        self.app = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.app)
        self.temp = tempfile.TemporaryDirectory(prefix='portable 用户 & ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'runtime/python').mkdir(parents=True)
        (self.root / 'runtime/python/python.exe').write_bytes(b'fixture')
        self.example = {'archive_root':'./archive', 'catalog_path':'./archive/catalog.sqlite', 'tools':{'python':''}, 'safety':{'default_dry_run':True}}
        (self.root / 'archive.config.example.json').write_text(json.dumps(self.example), encoding='utf-8')

    def test_new_config_uses_relocatable_runtime_and_no_archive(self):
        config = self.app.ensure_config(self.root)
        result = json.loads(config.read_text(encoding='utf-8'))
        self.assertEqual(result['tools']['python'], './runtime/python/python.exe')
        self.assertTrue(result['safety']['default_dry_run'])
        self.assertFalse((self.root/'archive').exists())

    def test_existing_config_is_byte_preserved(self):
        config = self.root / 'archive.config.json'
        raw = b'{"archive_root":"custom", "tools":{"python":"external"}}' + bytes([13,10])
        config.write_bytes(raw)
        self.assertEqual(self.app.ensure_config(self.root).read_bytes(), raw)

    def test_explicit_config_is_never_created(self):
        with self.assertRaises(FileNotFoundError):
            self.app.ensure_config(self.root, self.root/'missing.json')
        self.assertFalse((self.root/'missing.json').exists())

    def test_explicit_config_not_changed(self):
        config = self.root/'custom.json'
        config.write_text('{}',encoding='utf-8')
        self.assertEqual(self.app.ensure_config(self.root, config), config.resolve())
        self.assertEqual(config.read_bytes(),b'{}')

    def test_missing_runtime_refused(self):
        (self.root/'runtime/python/python.exe').unlink()
        with self.assertRaises(FileNotFoundError): self.app.ensure_config(self.root)
        self.assertFalse((self.root/'archive.config.json').exists())

    def test_ps_explicit_path_must_exist(self):
        with self.assertRaises(FileNotFoundError): self.app.find_powershell(str(self.root/'absent.exe'))
        candidate = self.root/'pwsh.exe'; candidate.write_bytes(b'fixture')
        self.assertEqual(self.app.find_powershell(str(candidate)),str(candidate.resolve()))

    def test_ps_falls_back_to_windows_builtin(self):
        candidate = self.root/'System32/WindowsPowerShell/v1.0/powershell.exe'
        candidate.parent.mkdir(parents=True); candidate.write_bytes(b'fixture')
        with patch.dict('os.environ', {'SystemRoot':str(self.root),'ProgramFiles':str(self.root/'none')},clear=True), patch.object(self.app.shutil,'which',return_value=None):
            self.assertEqual(self.app.find_powershell(),str(candidate))

    def test_occupied_port_chooses_another_not_existing_service(self):
        from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
        first = ThreadingHTTPServer(('127.0.0.1',0),BaseHTTPRequestHandler)
        self.addCleanup(first.server_close)
        bridge = self.app.load_bridge(self.root)
        manager = type('Manager',(),{})()
        second = self.app.open_server(bridge,manager,first.server_port)
        self.addCleanup(second.server_close)
        self.assertEqual(second.server_address[0],'127.0.0.1')
        self.assertNotEqual(first.server_port,second.server_port)

    def test_safe_stop_waits_for_active_worker(self):
        class Process:
            def poll(self): return None
        m=type('Manager',(),{'jobs':{'x':{'process':Process()}}})()
        self.assertFalse(self.app.is_idle(m))
        m.jobs.clear();self.assertTrue(self.app.is_idle(m))

if __name__ == '__main__': unittest.main()
