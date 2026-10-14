"""Read a small, explicit field allowlist from XML or binary iPhone backup plists.

No passwords, keybags, UDIDs, serial numbers, phone numbers or device nicknames
are emitted. Missing/malformed metadata is UNKNOWN, never guessed from mtime.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import plistlib
from xml.parsers.expat import ExpatError
from pathlib import Path

def extract(root: Path):
    documents={}; provenance={}; warnings=[]; fingerprints=[]
    for name in ('Info.plist','Manifest.plist','Status.plist'):
        path=root/name
        if not path.is_file(): continue
        try:
            if path.stat().st_size > 64*1024*1024:
                warnings.append(f'{name}: metadata exceeds 64 MiB; not parsed');continue
            raw=path.read_bytes()
            fingerprints.append({'file':name,'sha256':hashlib.sha256(raw).hexdigest()})
            value=plistlib.loads(raw)
            if not isinstance(value,dict): raise ValueError('Not a dictionary')
            documents[name]=value
        except (OSError,ValueError,TypeError,OverflowError,plistlib.InvalidFileException,ExpatError):
            warnings.append(f'{name}: unreadable or malformed; fields remain unknown')
    info=documents.get('Info.plist',{});manifest=documents.get('Manifest.plist',{})
    def pick_text(field,keys):
        for key in keys:
            value=info.get(key)
            if isinstance(value,str) and value.strip():
                provenance[field]=f'Info.plist:{key}';return value.strip()
        return None
    product=pick_text('product_type',['Product Type'])
    device=pick_text('device',['Product Name'])
    if not device and product:
        device=product;provenance['device']='Info.plist:Product Type (hardware identifier; model name not inferred)'
    version=pick_text('ios',['Product Version'])
    encrypted=manifest.get('IsEncrypted')
    if isinstance(encrypted,bool): provenance['encrypted']='Manifest.plist:IsEncrypted'
    else: encrypted=None
    backup_date=None
    for name,key in [('Info.plist','Last Backup Date'),('Status.plist','Date'),('Manifest.plist','Date')]:
        value=documents.get(name,{}).get(key)
        if isinstance(value,dt.datetime):
            if value.tzinfo is None:value=value.replace(tzinfo=dt.timezone.utc)
            backup_date=value.astimezone(dt.timezone.utc).isoformat().replace('+00:00','Z')
            provenance['backup_date']=f'{name}:{key}';break
    return {'schema_version':1,'kind':'iphone_backup','device':device,'product_type':product,
            'backup_date':backup_date,'encrypted':encrypted,'ios':version,'backup_folder_id':'***',
            'provenance':provenance,'metadata_files':fingerprints,'warnings':warnings}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,required=True)
    a=p.parse_args();print(json.dumps(extract(a.source),ensure_ascii=True))
