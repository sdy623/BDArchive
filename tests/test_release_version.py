from pathlib import Path
import json,re,unittest,xml.etree.ElementTree as ET
R=Path(__file__).resolve().parents[1]
class ReleaseVersionTests(unittest.TestCase):
 def test_public_version_is_consistent(self):
  self.assertEqual((R/'VERSION').read_text().strip(),'0.3.0')
  p=json.loads((R/'ui/package.json').read_text());lock=json.loads((R/'ui/package-lock.json').read_text())
  self.assertEqual(p['version'],'0.3.0');self.assertEqual(lock['version'],'0.3.0');self.assertEqual(lock['packages']['']['version'],'0.3.0')
  s=(R/'packaging/Launcher.cs').read_text(encoding='utf-8')
  for x in ('AssemblyVersion("0.3.0.0")','AssemblyFileVersion("0.3.0.0")','AssemblyInformationalVersion("0.3.0")'):self.assertIn(x,s)
  manifest=ET.parse(R/'packaging/app.manifest').getroot();self.assertEqual(manifest.find('{urn:schemas-microsoft-com:asm.v1}assemblyIdentity').attrib['version'],'0.3.0.0')
 def test_ui_uses_package_version_not_old_workbench_number(self):
  s=(R/'ui/src/App.tsx').read_text(encoding='utf-8');self.assertIn('appVersion',s);self.assertNotIn('REACT WORKBENCH / 2.0',s)
 def test_portable_batch_prefers_native_exe(self):
  s=(R/'START.bat').read_text(encoding='utf-8');self.assertIn('if exist "%~dp0BDArchive.exe"',s);self.assertLess(s.index('BDArchive.exe'),s.index('where pwsh.exe'))
 def test_release_docs_name_real_entry(self):
  for name in ('README.md','README.zh-CN.md','packaging/PORTABLE.md'):
   s=(R/name).read_text(encoding='utf-8');self.assertIn('BDArchive.exe',s);self.assertIn('0.3.0',s);self.assertNotIn('BD-Archive.exe',s)
 def test_builder_keeps_version_docs_and_scripts(self):
  s=(R/'packaging/build-portable.py').read_text(encoding='utf-8');self.assertIn("'VERSION'",s);self.assertIn("'application_version'",s);self.assertIn("glob('*.bat')",s)
if __name__=='__main__':unittest.main()
