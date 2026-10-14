import hashlib, importlib.util, io, pathlib, tarfile, unittest
p=pathlib.Path(__file__).resolve().parents[1]/'catalog/verify_tar_stream.py'
s=importlib.util.spec_from_file_location('verify_tar_stream',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
def expected(name, data):return {'path':name,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
def archive(entries):
 b=io.BytesIO()
 with tarfile.open(fileobj=b,mode='w',format=tarfile.PAX_FORMAT) as t:
  for name,data,kind,target in entries:
   x=tarfile.TarInfo(name);x.type=kind;x.linkname=target;x.size=len(data) if kind==tarfile.REGTYPE else 0;t.addfile(x,io.BytesIO(data) if kind==tarfile.REGTYPE else None)
 b.seek(0);return b
class StreamTests(unittest.TestCase):
 def test_unicode_and_forward_hardlink(self):
  data=b'payload';b=archive([('copy',b'',tarfile.LNKTYPE,'目录/a'),('目录/a',data,tarfile.REGTYPE,'')])
  self.assertEqual(m.verify(b,[expected('copy',data),expected('目录/a',data)])['files'],2)
 def test_corrupt_content(self):
  with self.assertRaisesRegex(ValueError,'hash mismatch'):m.verify(archive([('a',b'bad',tarfile.REGTYPE,'')]),[expected('a',b'yes')])
 def test_missing_unexpected_duplicate(self):
  for entries in [[],[('b',b'x',tarfile.REGTYPE,'')],[('a',b'x',tarfile.REGTYPE,'')]*2]:
   with self.assertRaises(ValueError):m.verify(archive(entries),[expected('a',b'x')])
 def test_link_cycle_and_symlink(self):
  for entries in [[('a',b'',tarfile.LNKTYPE,'a')],[('a',b'',tarfile.SYMTYPE,'outside')]]:
   with self.assertRaises(ValueError):m.verify(archive(entries),[expected('a',b'x')])
 def test_large_payload_bounded_reads(self):
  data=b'z'*(3*1024*1024);r=m.verify(archive([('large',data,tarfile.REGTYPE,'')]),[expected('large',data)])
  self.assertEqual(r['payload_files_written'],0);self.assertEqual(r['payload_buffer_bytes'],1024*1024)
if __name__=='__main__':unittest.main()
