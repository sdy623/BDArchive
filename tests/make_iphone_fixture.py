"""Synthetic metadata only. Contains no actual iPhone backup or user identifiers."""
import datetime as dt
import pathlib
import plistlib
import sys
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=False)
(root/'Info.plist').write_bytes(plistlib.dumps({'Product Type':'iPhone14,5','Product Version':'17.6.1','Last Backup Date':dt.datetime(2025,1,17,12,34)},fmt=plistlib.FMT_BINARY))
(root/'Manifest.plist').write_bytes(plistlib.dumps({'IsEncrypted':True}))
(root/'Manifest.db').write_bytes(b'SYNTHETIC PLACEHOLDER - not a SQLite iPhone backup database')
