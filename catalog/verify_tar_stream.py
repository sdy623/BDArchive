"""Verify a DwarFS pax stream against ingest. No payload is written to disk.

The producer is a separate, directly owned process in ArchiveStreamingProcess;
cancellation stops both processes. Payload buffering is bounded (1 MiB hash
buffer + tar/pipe buffers); only expected/observed file metadata grows with N.
"""
import argparse
import hashlib
import json
import sys
import tarfile
import time


def verify(source, expected, progress=lambda *_: None):
    wanted = {f['path']: f for f in expected}
    if len(wanted) != len(expected):
        raise ValueError('Duplicate expected path')
    seen = {}; links = {}; bytes_read = 0; stamp = time.monotonic()
    buffer = bytearray(1024 * 1024)
    with tarfile.open(fileobj=source, mode='r|', bufsize=65536) as archive:
        for member in archive:
            name = member.name
            while name.startswith('./'): name = name[2:]
            if member.isdir():
                archive.members.clear(); continue
            if name not in wanted or name in seen or name in links:
                raise ValueError('Unexpected or duplicate stream path: ' + name)
            if member.islnk():
                target = member.linkname
                while target.startswith('./'): target = target[2:]
                links[name] = target
            elif member.isfile():
                if member.size != wanted[name]['size']:
                    raise ValueError('Size mismatch: ' + name)
                digest = hashlib.sha256()
                stream = archive.extractfile(member)
                with stream:
                    while True:
                        count = stream.readinto(buffer)
                        if not count: break
                        digest.update(memoryview(buffer)[:count]); bytes_read += count
                value = (member.size, digest.hexdigest())
                if value[1] != wanted[name]['sha256']:
                    raise ValueError('Content hash mismatch: ' + name)
                seen[name] = value
            else:
                raise ValueError('Unsupported stream entry: ' + name)
            archive.members.clear()  # tarfile's member cache is unnecessary.
            if time.monotonic() - stamp > 1:
                progress(len(seen) + len(links), len(wanted), bytes_read)
                stamp = time.monotonic()
    # Drain trailing tar padding until EOF so the producer cannot block on a
    # full pipe after tar's end marker. Its exit code is checked by the owner.
    while source.readinto(buffer): pass
    while links:
        resolved = []
        for name, target in links.items():
            if target in seen:
                value = seen[target]
                if value != (wanted[name]['size'], wanted[name]['sha256']):
                    raise ValueError('Hard-link content mismatch: ' + name)
                seen[name] = value; resolved.append(name)
        if not resolved: raise ValueError('Unresolved/cyclic hard links')
        for name in resolved: del links[name]
    if set(seen) != set(wanted): raise ValueError('Missing stream files')
    return {'status':'PASS','files':len(seen),'payload_bytes_read':bytes_read,
            'payload_buffer_bytes':len(buffer),'payload_files_written':0}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--expected', required=True)
    a = p.parse_args()
    try:
        with open(a.expected, encoding='utf-8-sig') as f: expected = json.load(f)
        def progress(done, total, count):
            print(f'Stream verify: {done}/{total} files, {count} bytes', flush=True)
        print(json.dumps(verify(sys.stdin.buffer, expected, progress)), flush=True)
    except Exception as exc:
        print('STREAM_VERIFY_FAIL: ' + str(exc), file=sys.stderr, flush=True)
        sys.exit(1)
