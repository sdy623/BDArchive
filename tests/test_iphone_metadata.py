import datetime as dt
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('iphone_metadata',ROOT/'catalog'/'iphone_metadata.py')
metadata=importlib.util.module_from_spec(spec);spec.loader.exec_module(metadata)

class MetadataTests(unittest.TestCase):
    def setUp(self):
        work=ROOT/'work'/'metadata-tests';work.mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=work);self.root=pathlib.Path(self.temp.name)
        assert self.root.resolve().parent==work.resolve()
        self.addCleanup(self.temp.cleanup)
    def write(self,name,data,fmt=plistlib.FMT_XML):
        (self.root/name).write_bytes(plistlib.dumps(data,fmt=fmt))
    def test_xml_date_encryption_and_privacy_allowlist(self):
        self.write('Info.plist',{'Product Name':'iPhone 13','Product Type':'iPhone14,5',
            'Product Version':'17.6.1','Last Backup Date':dt.datetime(2025,1,17,12,34),
            'Device Name':'PRIVATE-NICKNAME','Serial Number':'PRIVATE-SERIAL','Target Identifier':'PRIVATE-UDID'})
        self.write('Manifest.plist',{'IsEncrypted':True,'BackupKeyBag':b'PRIVATE-KEYBAG'})
        r=metadata.extract(self.root)
        self.assertEqual(r['device'],'iPhone 13');self.assertTrue(r['encrypted'])
        self.assertEqual(r['backup_date'],'2025-01-17T12:34:00Z')
        self.assertEqual(r['backup_folder_id'],'***');self.assertNotIn('PRIVATE-',json.dumps(r))
    def test_binary_plist_and_hardware_identifier_fallback(self):
        self.write('Info.plist',{'Product Type':'iPhone14,5','Product Version':'17.6.1'},plistlib.FMT_BINARY)
        self.write('Manifest.plist',{'IsEncrypted':False},plistlib.FMT_BINARY)
        r=metadata.extract(self.root);self.assertEqual(r['device'],'iPhone14,5');self.assertFalse(r['encrypted'])
        self.assertIsNone(r['backup_date'])
    def test_missing_metadata_is_unknown_not_unencrypted(self):
        r=metadata.extract(self.root)
        self.assertIsNone(r['encrypted']);self.assertIsNone(r['device']);self.assertIsNone(r['backup_date'])
    def test_bad_types_not_coerced_to_success(self):
        self.write('Manifest.plist',{'IsEncrypted':'YES','Date':'2025-01-17'})
        r=metadata.extract(self.root);self.assertIsNone(r['encrypted']);self.assertIsNone(r['backup_date'])
    def test_malformed_metadata_preserves_other_valid_fields(self):
        (self.root/'Info.plist').write_bytes(b'not a plist')
        self.write('Manifest.plist',{'IsEncrypted':True})
        r=metadata.extract(self.root);self.assertTrue(r['encrypted']);self.assertTrue(r['warnings'])
    def test_date_fallback_has_provenance(self):
        self.write('Status.plist',{'Date':dt.datetime(2024,2,3)})
        r=metadata.extract(self.root)
        self.assertEqual(r['backup_date'],'2024-02-03T00:00:00Z')
        self.assertEqual(r['provenance']['backup_date'],'Status.plist:Date')

if __name__=='__main__':unittest.main()
