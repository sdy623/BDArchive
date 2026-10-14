"""Branding regressions: resolved type stacks and native multi-size application icon."""
from pathlib import Path
import importlib.util,struct,unittest
ROOT=Path(__file__).resolve().parents[1]
class TypographyIconTests(unittest.TestCase):
 def test_type_stacks_are_explicit_and_cjk_safe(self):
  css=(ROOT/'ui/src/styles.css').read_text(encoding='utf-8')
  for token in ('--font-ui:', '--font-mono:', '--font-display:', 'Consolas', 'Microsoft YaHei UI'):
   self.assertIn(token,css)
  self.assertNotIn('font-family:monospace',css)
  self.assertNotIn("font-family:'IBM Plex Mono'",css)
  self.assertIn('font-family:var(--font-mono)',css)
  self.assertIn('document.documentElement.lang=lang',(ROOT/'ui/src/App.tsx').read_text(encoding='utf-8'))
 def test_bundled_mono_semibold_is_registered(self):
  css=(ROOT/'ui/src/styles.css').read_text(encoding='utf-8')
  self.assertIn('ibm-plex-mono-600.ttf',css)
  self.assertIn('strong,b{font-weight:600}',css)
 def test_icon_has_native_small_to_hidpi_frames(self):
  data=(ROOT/'assets/branding/bdarchive.ico').read_bytes()
  reserved,kind,count=struct.unpack_from('<HHH',data)
  self.assertEqual((reserved,kind),(0,1));self.assertEqual(count,8)
  sizes=[]
  for i in range(count):
   w,h,_,_,planes,bpp,n,off=struct.unpack_from('<BBBBHHII',data,6+16*i)
   sizes.append(w or 256);self.assertEqual(w,h);self.assertEqual((planes,bpp),(1,32));self.assertEqual(data[off:off+4],struct.pack('<I',40)) if (w or 256)<=64 else self.assertEqual(data[off:off+8],b'\x89PNG\r\n\x1a\n');self.assertLessEqual(off+n,len(data))
  self.assertEqual(sizes,[16,20,24,32,48,64,128,256])
 def test_icon_is_bound_to_exe_window_and_sidebar(self):
  self.assertIn('/win32icon:',(ROOT/'packaging/build-portable.py').read_text(encoding='utf-8'))
  self.assertIn('Icon=new Icon(', (ROOT/'packaging/Launcher.cs').read_text(encoding='utf-8'))
  self.assertIn('brandMark', (ROOT/'ui/src/App.tsx').read_text(encoding='utf-8'))
 def test_only_reviewed_icon_bytes_pass_public_guard(self):
  spec=importlib.util.spec_from_file_location('guard',ROOT/'scripts/check-public-export.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
  data=(ROOT/'assets/branding/bdarchive.ico').read_bytes()
  self.assertEqual(m.inspect_file('assets/branding/bdarchive.ico',data),[])
  self.assertTrue(m.inspect_file('assets/branding/bdarchive.ico',data+b'tamper'))
  self.assertTrue(m.inspect_file('unreviewed.ico',data))
if __name__=='__main__':unittest.main()
