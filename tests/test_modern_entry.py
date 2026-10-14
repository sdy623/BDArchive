import json, pathlib, unittest
R=pathlib.Path(__file__).resolve().parents[1]
class ModernEntry(unittest.TestCase):
 def test_react_entry(self):
  p=json.loads((R/'ui/package.json').read_text())
  self.assertEqual(p['dependencies']['react'],'19.2.6')
  self.assertTrue((R/'ui/src/main.tsx').is_file())
 def test_default_route_is_web(self):
  text=(R/'scripts/archive-ui.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('[switch]$LegacyUi',text)
  self.assertIn('start-workbench.ps1',text)
 def test_restrained_custom_controls(self):
  css=(R/'ui/src/styles.css').read_text(encoding='utf-8')
  app=(R/'ui/src/App.tsx').read_text(encoding='utf-8')
  self.assertRegex(css,r'\.button\{[^}]*border-radius:6px')
  self.assertRegex(css,r'\.card\{[^}]*border-radius:10px')
  self.assertNotIn('<select',app)
  self.assertIn('role="listbox"',app)
  self.assertIn('role="checkbox"',app)
  self.assertIn('role="radio"',app)
 def test_startup_does_not_burn(self):
  text=(R/'scripts/start-workbench.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('workbench.py',text)
  self.assertNotIn('Invoke-Archive',text)
if __name__=='__main__':unittest.main()
