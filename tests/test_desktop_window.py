"""Regression: a desktop EXE must host the UI, not open an external browser."""
import ast
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class DesktopWindowTests(unittest.TestCase):
    def test_launcher_hosts_webview_and_sta_message_loop(self):
        source=(ROOT/'packaging/Launcher.cs').read_text(encoding='utf-8')
        for needed in ('WebView2','[STAThread]','Application.Run','CreateNoWindow=true','--no-open'):
            self.assertIn(needed,source)
    def test_exe_is_windowed_subsystem(self):
        source=(ROOT/'packaging/build-portable.py').read_text(encoding='utf-8')
        self.assertIn('/target:winexe',source)
    def test_backend_has_no_browser_open_capability(self):
        source=(ROOT/'catalog/desktop_entry.py').read_text(encoding='utf-8')
        self.assertNotIn('webbrowser',source)
    def test_close_requires_backend_idle_acknowledgement(self):
        source=(ROOT/'packaging/Launcher.cs').read_text(encoding='utf-8')
        for needed in ('FormClosing','stopFile','HasExited'):
            self.assertIn(needed,source)
    def test_arbitrary_external_navigation_is_blocked(self):
        source=(ROOT/'packaging/Launcher.cs').read_text(encoding='utf-8')
        for needed in ('NavigationStarting','NewWindowRequested','PermissionRequested','IsWebMessageEnabled=false','AreHostObjectsAllowed=false'):
            self.assertIn(needed,source)
    def test_manifest_per_monitor_v2(self):
        self.assertIn('PerMonitorV2',(ROOT/'packaging/app.manifest').read_text(encoding='utf-8'))
if __name__=='__main__':unittest.main()
