"""Stdlib-only SQLite index and read-only NFC metadata service.

catalog.json is authoritative; sync is an atomic snapshot replacement.
No HTTP endpoint can burn, delete, register or change archive data.
"""
from __future__ import annotations
import argparse
import hashlib
import html
import json
import re
import sqlite3
import sys
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit, quote, parse_qs

SCHEMA = Path(__file__).with_name('schema.sql')

# Package assets only: no general static-file handler and no archive/config paths.
# Each route resolves to one literal bundled font filename, never user input.
FONT_ROOT = Path(__file__).resolve().parents[1] / 'assets' / 'fonts'
FONT_FILES = {
    '/assets/fonts/barlow-condensed-400.ttf': FONT_ROOT / 'barlow-condensed-400.ttf',
    '/assets/fonts/barlow-condensed-600.ttf': FONT_ROOT / 'barlow-condensed-600.ttf',
    '/assets/fonts/ibm-plex-sans-400.ttf': FONT_ROOT / 'ibm-plex-sans-400.ttf',
    '/assets/fonts/ibm-plex-sans-600.ttf': FONT_ROOT / 'ibm-plex-sans-600.ttf',
    '/assets/fonts/ibm-plex-mono-400.ttf': FONT_ROOT / 'ibm-plex-mono-400.ttf',
    '/assets/fonts/ibm-plex-mono-600.ttf': FONT_ROOT / 'ibm-plex-mono-600.ttf',
}


def sync_sealed_content(con, catalog):
    """Rebuild searchable event metadata only from catalog-bound sealed indexes."""
    events, files = [], []
    for disc in catalog['discs']:
        seal = disc.get('stage') or {}
        if not seal.get('path') or disc.get('catalog_deleted'):
            continue
        root = Path(seal['path'])
        index = root / 'data/00_CONTENT_INDEX'
        if not (index / '内容索引.json').is_file():
            continue
        raw = (root / 'SHA256SUMS').read_bytes()
        if hashlib.sha256(raw).hexdigest() != seal.get('hash') or disc.get('hash') != seal.get('hash'):
            raise ValueError('Content index seal does not match catalog')
        sums = {}
        for line in raw.decode('utf-8-sig').splitlines():
            match = re.fullmatch(r'([a-f0-9]{64})  (.+)', line)
            if not match or match[2] in sums:
                raise ValueError('Invalid content seal')
            sums[match[2]] = match[1]
        def read(name):
            data = (index / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != sums.get('data/00_CONTENT_INDEX/' + name):
                raise ValueError('Sealed content index changed: ' + name)
            return json.loads(data.decode('utf-8-sig'))
        content, layout = read('内容索引.json'), read('分盘清单.json')
        selected = [d for d in layout if d['disc_id'] == disc['disc_id']]
        if len(selected) != 1:
            raise ValueError('Content index disc identity mismatch')
        sources = {s['number']: s for s in content['sources']}
        split = read('分段校验.json') if any(f.get('part') for f in selected[0]['files']) else None
        for f in selected[0]['files']:
            if sums.get('data/' + f['name']) != f['expected_sha256']:
                raise ValueError('Indexed recording does not match sealed payload')
            files.append((disc['disc_id'], f['video'], f.get('part') or 0, f['name'], f['bytes'], f['expected_sha256']))
            start, end = 0, float(sources[f['video']]['duration'])
            if f.get('part'):
                part = int(f['part'])
                start = float(split['parts'][part-1]['source_start_seconds'])
                if part < len(split['parts']):
                    end = float(split['parts'][part]['source_start_seconds'])
            for e in content['events']:
                if e['video'] == f['video'] and start <= e['start'] < end:
                    events.append((disc['disc_id'], e['id'], e['video'], e['start'], e['end'], max(0, e['start']-start), e['title'], e['description'], e['kind'], f['name'], json.dumps(e, ensure_ascii=False)))
    con.execute('CREATE TABLE IF NOT EXISTS content_files (disc_id TEXT,video INTEGER,part INTEGER,filename TEXT,bytes INTEGER,sha256 TEXT,PRIMARY KEY(disc_id,filename))')
    con.execute('CREATE TABLE IF NOT EXISTS content_events (disc_id TEXT,event_id TEXT,video INTEGER,start_seconds REAL,end_seconds REAL,disc_seconds REAL,title TEXT,description TEXT,kind TEXT,filename TEXT,event_json TEXT,PRIMARY KEY(disc_id,event_id))')
    con.execute('DELETE FROM content_events')
    con.execute('DELETE FROM content_files')
    con.executemany('INSERT INTO content_files VALUES(?,?,?,?,?,?)', files)
    con.executemany('INSERT INTO content_events VALUES(?,?,?,?,?,?,?,?,?,?,?)', events)

def content_details(con, disc_id, language='en'):
    if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='content_events'").fetchone():
        return ''
    rows = con.execute('SELECT * FROM content_events WHERE disc_id=? ORDER BY video,start_seconds', (disc_id,)).fetchall()
    if not rows:
        return ''
    def clock(value):
        seconds = int(value)
        return f'{seconds//3600:02}:{seconds//60%60:02}:{seconds%60:02}'
    body = f'<section><h2>{html.escape(tr("events", language))}</h2><p>{html.escape(tr("events_note", language))}</p>' 
    for event in rows:
        body += (f'<p><strong>V{event["video"]:02} · {clock(event["start_seconds"])} · {html.escape(event["title"])}</strong><br>'
                 f'{html.escape(event["description"])}<br>{tr("disc_time", language)} {clock(event["disc_seconds"])} · {html.escape(event["filename"])}</p>')
    return body + '</section>'
IDENTITY_JOIN = ('SELECT d.*,i.catalog_id,i.disc_index,i.disc_prefix,i.disc_number,'
                 'i.volume_id,i.volume_index,i.volume_count,i.volume_label,'
                 'i.filesystem_serial,i.identity_origin,COALESCE(l.catalog_deleted,0) AS catalog_deleted,'
                 'l.deleted_at,l.delete_reason FROM discs d '
                 'LEFT JOIN disc_identity i USING(disc_id) LEFT JOIN disc_lifecycle l USING(disc_id)')

def identity(item):
    match = re.fullmatch(r'([A-Z][A-Z0-9_-]*?)([0-9]+)', item['disc_id'])
    if not match or len(item['disc_id']) > 32:
        raise ValueError('Invalid disc ID')
    stem, number = match.groups()
    prefix = stem[3:-1] if re.fullmatch(r'BD-[PGBM]-', stem) else stem.rstrip('-_')
    verification = item.get('verification') or {}
    media = verification.get('media') or {}
    return (item['disc_id'], item.get('catalog_id'), item.get('disc_index'), prefix, int(number),
            item.get('volume_id') or f"{item['archive_set_id']}-V{item['position']:04d}",
            item['position'], item['disc_count'], item.get('volume_label') or item['disc_id'],
            media.get('volume_serial') if verification and not verification.get('simulation') else None,
            item.get('identity_origin') or 'derived_legacy')

@contextmanager
def connect(db: Path, readonly: bool = False):
    if readonly:
        uri = db.resolve().as_uri() + '?mode=ro'
        con = sqlite3.connect(uri, uri=True, timeout=10)
    else:
        db.parent.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(db, timeout=10)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA foreign_keys=ON')
    try:
        with con:
            yield con
    finally:
        con.close()

def sync(source: Path, db: Path):
    catalog = json.loads(source.read_text(encoding='utf-8-sig'))
    if catalog['schema_version'] != 1:
        raise ValueError('Unsupported catalog schema')
    with connect(db) as con:
        con.executescript(SCHEMA.read_text(encoding='utf-8'))
        con.execute('BEGIN IMMEDIATE')
        con.execute('DELETE FROM disc_aliases')
        con.execute('DELETE FROM set_aliases')
        con.execute('DELETE FROM disc_lifecycle')
        con.execute('DELETE FROM disc_metadata')
        con.execute('DELETE FROM disc_identity')
        con.execute('DELETE FROM id_counters')
        con.execute('DELETE FROM set_details')
        con.execute('DELETE FROM discs')
        con.execute('DELETE FROM archive_sets')
        for item in catalog['sets']:
            con.execute('INSERT INTO archive_sets VALUES(?,?,?,?,?,?,?,?)', (
                item['archive_set_id'], item['category'], item.get('summary') or '',
                item['file_count'], item['total_bytes'], int(item['original_deleted']),
                (item.get('restore_test') or {}).get('status'), item['ingest_sha256']))
            if item.get('summary_details'):
                con.execute('INSERT INTO set_details VALUES(?,?)',(
                    item['archive_set_id'],json.dumps(item['summary_details'],ensure_ascii=False)))
        for item in catalog['discs']:
            verification = item.get('verification') or {}
            con.execute('INSERT INTO discs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)', (
                item['disc_id'], item['archive_set_id'], item['position'], item['disc_count'],
                item['media_type'], item.get('burn_date'), item.get('hash'), item['status'],
                item.get('location') or '', item['nfc_url'], int(item['original_deleted']),
                int(item['registered']), verification.get('status'),
                None if not verification else int(verification['simulation'])))
            con.execute('INSERT INTO disc_identity VALUES(?,?,?,?,?,?,?,?,?,?,?)', identity(item))
            con.execute('INSERT INTO disc_lifecycle VALUES(?,?,?,?)', (item['disc_id'],int(bool(item.get('catalog_deleted'))),item.get('catalog_deleted_at'),item.get('catalog_delete_reason')))
            if item.get('authoring_metadata'):
                con.execute('INSERT INTO disc_metadata VALUES(?,?)',(item['disc_id'],json.dumps(item['authoring_metadata'],ensure_ascii=False)))
        for table, key, collection, pattern in (
            ('disc_aliases','disc_id','discs',r'[A-Z][A-Z0-9_-]*[0-9]'),
            ('set_aliases','archive_set_id','sets',r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}')):
            current = {d[key].casefold() for d in catalog[collection]}
            seen = set()
            for alias in catalog.get(table, []):
                old, new = alias['old_id'], alias['new_id']
                if (not re.fullmatch(pattern, old) or old.casefold() in current or
                    old.casefold() in seen or new.casefold() not in current):
                    raise ValueError('Invalid, duplicate or conflicting ID alias')
                seen.add(old.casefold())
                con.execute(f'INSERT INTO {table} VALUES(?,?)', (old, new))
        for prefix in ('P','G','B','M'):
            high = max([catalog.get('sequences', {}).get(prefix, 0)] + [
                int(d['disc_id'].split('-')[2]) for d in catalog['discs']
                if re.fullmatch(r'BD-' + prefix + r'-[0-9]+', d['disc_id'])])
            con.execute('INSERT INTO id_counters VALUES(?,?,?)', (prefix, high, high+1))
        con.execute('INSERT OR REPLACE INTO catalog_meta VALUES(?,?)', ('catalog_id', catalog.get('catalog_id') or ''))
        con.execute('INSERT OR REPLACE INTO catalog_meta VALUES(?,?)', ('snapshot_time', catalog['updated_at']))
        sync_sealed_content(con, catalog)
    return {'sets': len(catalog['sets']), 'discs': len(catalog['discs']), 'db': str(db)}

def rows(db: Path, include_deleted: bool = False):
    with connect(db, True) as con:
        return [dict(row) for row in con.execute(IDENTITY_JOIN + ('' if include_deleted else ' WHERE COALESCE(l.catalog_deleted,0)=0') + ' ORDER BY i.disc_index,d.disc_id')]

LABELS_ZH = {'disc_id': '盘号',
 'archive_set_id': 'Archive Set',
 'summary': '内容摘要',
 'position': '盘序号',
 'disc_count': '总盘数',
 'media_type': '介质',
 'status': '状态',
 'location': '物理位置',
 'burn_date': '刻录时间',
 'hash': 'SHA256SUMS 的 SHA-256',
 'original_deleted': '原件已删除',
 'simulation': '模拟验证',
 'verification_status': '校验结果',
 'restore_status': '恢复演练',
 'nfc_url': '稳定 URL',
 'device': 'Device',
 'device_source': '设备信息来源',
 'backup_date': 'Backup date',
 'encrypted': 'Encrypted',
 'ios': 'iOS',
 'backup_folder_id': 'Backup folder ID',
 'disc_set_label': 'Disc set label',
 'second_copy': 'Second copy（用户记录）',
 'password_storage': 'Encryption password storage（仅保管位置）',
 'scenario': '场景',
 'photo_tier': '照片层级',
 'date_range': '日期范围（用户填写）',
 'camera': '相机（用户填写）',
 'tags': '标签（用户填写）',
 'raw_files': 'RAW 文件',
 'preview_files': '预览图片文件',
 'master_files': '精修/母版文件',
 'sidecar_files': '侧车文件',
 'other_files': '其他文件',
 'photo_families': '照片家族',
 'photo_policy': '保存策略',
 'metadata_note': '摘要说明',
 'game': '游戏',
 'master_status': '现存 master 类型',
 'earlier_original_status': '更早原始录像状态（用户填写）',
 'video_files': '录像文件',
 'catalog_id': '归档库 ID',
 'disc_index': '全库碟片索引',
 'disc_prefix': '盘号类别',
 'disc_number': '类别内编号',
 'volume_id': 'Volume ID（逻辑卷号）',
 'volume_index': '卷序',
 'volume_count': '总卷数',
 'volume_label': 'UDF 卷标',
 'filesystem_serial': 'Windows 文件系统序列号（真实回读）',
 'identity_origin': '编号记录来源',
 'catalog_deleted': '记录已从目录删除（可恢复）',
 'deleted_at': '记录删除时间',
 'delete_reason': '记录删除原因',
 'category': '类别',
 'file_count': '文件数',
 'total_bytes': '总字节数',
 'ingest_sha256': '扫描清单 SHA-256',
 'registered': '已登记',
 'publisher': '出版者',
 'data_preparer': '数据准备者',
 'application': '应用程序',
 'system': '系统',
 'volume_set': '卷组',
 'udf': 'UDF',
 'iso9660': 'ISO9660',
 'joliet': 'Joliet'}

LABELS_EN = {'disc_id': 'Disc ID',
 'archive_set_id': 'Archive Set',
 'summary': 'Content summary',
 'position': 'Disc position',
 'disc_count': 'Total discs',
 'media_type': 'Media type',
 'status': 'Status',
 'location': 'Physical location',
 'burn_date': 'Burn date',
 'hash': 'SHA-256 of SHA256SUMS',
 'original_deleted': 'Originals deleted',
 'simulation': 'Simulated verification',
 'verification_status': 'Verification result',
 'restore_status': 'Restore exercise',
 'nfc_url': 'Stable URL',
 'device': 'Device',
 'device_source': 'Device metadata source',
 'backup_date': 'Backup date',
 'encrypted': 'Encrypted',
 'ios': 'iOS',
 'backup_folder_id': 'Backup folder ID',
 'disc_set_label': 'Disc set label',
 'second_copy': 'Second copy (user record)',
 'password_storage': 'Encryption password reference (storage location only)',
 'scenario': 'Archive type',
 'photo_tier': 'Photo tier',
 'date_range': 'Date range (user supplied)',
 'camera': 'Camera (user supplied)',
 'tags': 'Tags (user supplied)',
 'raw_files': 'RAW files',
 'preview_files': 'Preview images',
 'master_files': 'Edited / master files',
 'sidecar_files': 'Sidecar files',
 'other_files': 'Other files',
 'photo_families': 'Photo families',
 'photo_policy': 'Retention policy',
 'metadata_note': 'Summary note',
 'game': 'Game',
 'master_status': 'Existing master type',
 'earlier_original_status': 'Earlier recording status (user supplied)',
 'video_files': 'Video files',
 'catalog_id': 'Library ID',
 'disc_index': 'Catalog disc index',
 'disc_prefix': 'Disc category',
 'disc_number': 'Number within category',
 'volume_id': 'Volume ID (logical)',
 'volume_index': 'Volume position',
 'volume_count': 'Total volumes',
 'volume_label': 'UDF volume label',
 'filesystem_serial': 'Windows filesystem serial (physical readback)',
 'identity_origin': 'Identity record source',
 'catalog_deleted': 'Record deleted from catalog (recoverable)',
 'deleted_at': 'Record deletion time',
 'delete_reason': 'Record deletion reason',
 'category': 'Category',
 'file_count': 'File count',
 'total_bytes': 'Total bytes',
 'ingest_sha256': 'Ingest SHA-256',
 'registered': 'Registered',
 'publisher': 'Publisher',
 'data_preparer': 'Data preparer',
 'application': 'Application',
 'system': 'System',
 'volume_set': 'Volume set',
 'udf': 'UDF',
 'iso9660': 'ISO9660',
 'joliet': 'Joliet'}

CATALOG_TEXT = {
    'catalog': ('BD Archive Catalog', 'BD 光盘归档目录'),
    'home': ('Cold archive catalog', '冷数据光盘目录'),
    'ids': ('IDs & labels', '编号与卷标'),
    'deleted': ('Deleted records', '已删除记录'),
    'deleted_title': ('Deleted records / restore in the desktop tool', '已删除记录（可在工具中恢复）'),
    'read_only': ('Read-only catalog', '只读目录'),
    'tagline': ('OFFLINE BY DESIGN. READABLE FOR YEARS.', '离线保存 / 长期可读'),
    'missing': ('Not recorded', '未记录'),
    'pending': ('Pending index', '待补全'),
    'next_note': ('Next IDs for this library. Viewing does not reserve a number.', '当前归档库的下一号；查看不会占号。'),
    'used': ('last allocated', '已用到'),
    'next': ('next disc', '下一张'),
    'index': ('index', '索引'),
    'open_disc': ('Open disc record', '打开碟片记录'),
    'restore': ('Restore', '恢复'),
    'restore_note': ('Verify the disc SHA256SUMS first, then read RESTORE.md and SET-MANIFEST.json at the disc root. For backups, collect every DwarFS shard, extract each, merge by original path and verify.', '先校验光盘 SHA256SUMS；读取盘根目录 RESTORE.md 和 SET-MANIFEST.json。备份类需收集全套 DwarFS shard，分别解包后按原路径合并并校验。'),
    'simulation_warning': ('SIMULATED_PASS is a local simulation only, never permission to delete originals.', 'SIMULATED_PASS 仅为本地模拟，不能作为删除原件的依据。'),
    'events': ('Recording events & chapters', '录像事件与章节'),
    'events_note': ('Times refer to the source recording. Split segments also show the on-disc playback time. This is a local index; the record above is authoritative for physical burn status.', '时间为录像内时间；分段同时给出盘内播放时间。仅表示本地索引，实体刻录状态以上方记录为准。'),
    'disc_time': ('On disc', '盘内'),
    'language': ('Language', '语言'),
}


def language_code(value):
    """Only display language changes. Stable IDs and database values do not."""
    return value if value in ('en', 'zh-CN') else 'en'


def tr(key, language='en'):
    return CATALOG_TEXT[key][1 if language_code(language) == 'zh-CN' else 0]


def href(route, language='en'):
    return route + '?lang=' + language_code(language)


def anchor(route, label, language='en'):
    return f'<a href="{html.escape(href(route, language), quote=True)}">{html.escape(str(label))}</a>'


def page(title: str, body: str, language='en', path='/'):
    language = language_code(language)
    # Use only this route, not user query parameters, when switching language.
    route = quote(path if path.startswith('/') else '/', safe='/')
    switches = ' / '.join(
        f'<a lang="{code}" aria-current="{"true" if code == language else "false"}" href="{html.escape(href(route, code), quote=True)}">{name}</a>'
        for code, name in (('en', 'English'), ('zh-CN', '简体中文')))
    # Visual tokens and mission-console hierarchy adapted from the user's KSP
    # Mission Display globals.css and DESIGN.md section 10. Only design rules
    # are reused: no telemetry, KSP data or branding. See THIRD_PARTY_NOTICES.md.
    # Fonts are licensed package assets from the explicit allowlist below. No
    # remote assets, scripts or cookies; CSP permits same-origin fonts only.
    css = '''
@font-face{font-family:"Barlow Condensed";font-style:normal;font-weight:400;font-display:swap;src:url("/assets/fonts/barlow-condensed-400.ttf") format("truetype")}
@font-face{font-family:"Barlow Condensed";font-style:normal;font-weight:600;font-display:swap;src:url("/assets/fonts/barlow-condensed-600.ttf") format("truetype")}
@font-face{font-family:"IBM Plex Sans";font-style:normal;font-weight:400;font-display:swap;src:url("/assets/fonts/ibm-plex-sans-400.ttf") format("truetype")}
@font-face{font-family:"IBM Plex Sans";font-style:normal;font-weight:600;font-display:swap;src:url("/assets/fonts/ibm-plex-sans-600.ttf") format("truetype")}
@font-face{font-family:"IBM Plex Mono";font-style:normal;font-weight:400;font-display:swap;src:url("/assets/fonts/ibm-plex-mono-400.ttf") format("truetype")}
@font-face{font-family:"IBM Plex Mono";font-style:normal;font-weight:600;font-display:swap;src:url("/assets/fonts/ibm-plex-mono-600.ttf") format("truetype")}
:root{color-scheme:dark;--bg:#020408;--bg-soft:#07101A;--panel:rgba(8,16,26,0.86);
--panel-strong:#0A1420;--text:#F2F6FB;--muted:#8290A3;--cyan:#00A8E0;
--blue:#005288;--amber:#F2A900;--danger:#E8312A;--success:#39D98A;
--divider:rgba(255,255,255,0.14);--divider-soft:rgba(255,255,255,0.07);
--font-display:"Barlow Condensed","Arial Narrow","Microsoft YaHei UI",sans-serif;
--font-ui:"IBM Plex Sans","Segoe UI","Microsoft YaHei UI",sans-serif;
--font-mono:"IBM Plex Mono",Consolas,"Microsoft YaHei UI",monospace}
*{box-sizing:border-box}html{background:var(--bg);color-scheme:dark}
body{margin:0;min-height:100vh;color:var(--text);font:15px/1.6 var(--font-ui);
background:radial-gradient(circle at 18% -10%,rgba(0,82,136,0.26),transparent 34rem),linear-gradient(145deg,#020408 0%,#050B12 58%,#020408 100%)}
a{color:var(--cyan);text-decoration:none}a:hover{color:var(--text);text-decoration:underline;text-underline-offset:4px}
a:focus-visible{outline:2px solid var(--cyan);outline-offset:4px}
.mission-nav{max-width:1380px;min-height:78px;margin:auto;padding:16px 32px;display:grid;align-items:center;gap:24px;
grid-template-columns:minmax(220px,1fr) auto auto;border-bottom:1px solid var(--divider)}
.brand{display:inline-flex;align-items:center;gap:12px;width:max-content;color:var(--text);text-decoration:none}
.brand:hover{text-decoration:none}.brand-mark{display:inline-flex;align-items:center;justify-content:center;background:var(--cyan);color:#00131D;
width:38px;height:38px;font:600 22px/1 var(--font-display);transform:skewX(-8deg)}
.brand b{display:block;font:600 19px/1.2 var(--font-display);letter-spacing:.1em}
.brand small{display:block;color:var(--muted);font:9px/1.4 var(--font-mono);letter-spacing:.08em;margin-top:5px}
nav{display:flex;gap:24px;flex-wrap:wrap}nav a{color:#B9C5D2;font-size:13px;font-weight:600;letter-spacing:.05em}
.language{font:11px/1.6 var(--font-mono);white-space:nowrap}.language a{padding:6px;color:var(--muted)}
.language [aria-current=true]{color:var(--cyan);border-bottom:1px solid var(--cyan)}
main{max-width:1180px;margin:auto;padding:32px 28px 56px}.kicker{display:inline-flex;align-items:center;color:var(--cyan);border:1px solid var(--blue);
background:rgba(0,168,224,0.08);padding:5px 9px;font:10px/1.4 var(--font-mono);letter-spacing:.12em;text-transform:uppercase}
h1{font:600 clamp(28px,4vw,42px)/1.15 var(--font-display);letter-spacing:.02em;margin:12px 0 28px;overflow-wrap:anywhere}
h2{font:600 21px/1.3 var(--font-display);letter-spacing:.04em;margin:0 0 14px}
section{background:var(--panel);border:1px solid var(--divider);border-top:1px solid var(--blue);padding:20px 24px;margin:16px 0;border-radius:2px}
p{margin:0 0 12px}p:last-child{margin-bottom:0}dl{display:grid;grid-template-columns:minmax(190px,32%) minmax(0,1fr);margin:0;gap:0 28px}
dt,dd{margin:0;padding:10px 0;border-bottom:1px solid var(--divider-soft);overflow-wrap:anywhere}
dt{font-size:12px;font-weight:500;color:var(--muted)}dd{font:13px/1.7 var(--font-mono);font-variant-numeric:tabular-nums}
.notice{background:var(--panel-strong);border-left:3px solid var(--cyan)}.warning{color:var(--amber);font-weight:500;margin-top:14px}
footer{border-top:1px solid var(--divider);color:var(--muted);font:11px/1.7 var(--font-mono);padding-top:18px;margin-top:26px}
html[lang=zh-CN] h1,html[lang=zh-CN] h2,html[lang=zh-CN] nav a,html[lang=zh-CN] .kicker,html[lang=zh-CN] .brand small{letter-spacing:normal}
@media(max-width:850px){.mission-nav{padding:16px 20px;grid-template-columns:1fr auto;gap:16px}.mission-nav nav{grid-column:1/-1;grid-row:2}.language{grid-column:2;grid-row:1}.brand small{max-width:240px}}
@media(max-width:600px){main{padding:24px 16px 40px}section{padding:16px}dl{display:block}dt{border:0;padding:12px 0 0}dd{padding:3px 0 12px}.brand small{font-size:8px;max-width:190px}.language{font-size:10px}.brand b{font-size:17px}}
'''
    return (f'<!doctype html><html lang="{language}"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{html.escape(title)} / BD Archive</title><style>{css}</style></head><body>'
            f'<header class="mission-nav"><a class="brand" href="{href("/", language)}">'
            f'<span class="brand-mark" aria-hidden="true">BD</span><span><b>BD ARCHIVE</b>'
            f'<small>{html.escape(tr("tagline", language))}</small></span></a><nav>'
            f'{anchor("/", tr("catalog", language), language)}{anchor("/ids", tr("ids", language), language)}</nav>'
            f'<div class="language" aria-label="{html.escape(tr("language", language))}">{switches}</div></header>'
            f'<main><div class="kicker">{html.escape(tr("read_only", language))}</div>'
            f'<h1>{html.escape(title)}</h1>{body}<footer>{html.escape(tr("simulation_warning", language))}</footer>'
            '</main></body></html>').encode('utf-8')


def details(data, language='en'):
    labels = LABELS_ZH if language_code(language) == 'zh-CN' else LABELS_EN
    return '<section><dl>' + ''.join(
        f'<dt>{html.escape(labels.get(k, k))}</dt><dd>{html.escape(str(v) if v is not None else tr("missing", language))}</dd>'
        for k, v in data.items()) + '</dl></section>'


def backup_details(con, identifier, language='en'):
    row = con.execute('SELECT details_json FROM set_details WHERE archive_set_id=?', (identifier,)).fetchone()
    return details(json.loads(row[0]), language) if row else ''


def make_handler(db: Path):
    class Handler(BaseHTTPRequestHandler):
        def redirect_alias(self, con, table, identifier, route):
            if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                return False
            alias = con.execute(f'SELECT new_id FROM {table} WHERE old_id=?', (identifier,)).fetchone()
            if not alias:
                return False
            destination = route + quote(alias[0], safe='')
            if self.explicit_language:
                destination = href(destination, self.language)
            self.send_response(302)
            self.send_header('Location', destination)
            self.send_header('Content-Length', '0')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            return True

        def do_GET(self):
            parsed = urlsplit(self.path)
            path = unquote(parsed.path)
            query = parse_qs(parsed.query)
            language = language_code(query.get('lang', ['en'])[0])
            self.language = language
            self.explicit_language = 'lang' in query
            try:
                if path.startswith('/assets/'):
                    font_path = FONT_FILES.get(path)
                    if font_path is None:
                        return self.send_error(404)
                    data = font_path.read_bytes()
                    self.send_response(200)
                    self.send_header('Content-Type', 'font/ttf')
                    self.send_header('Content-Length', str(len(data)))
                    self.send_header('Cache-Control', 'public, max-age=86400')
                    self.send_header('X-Content-Type-Options', 'nosniff')
                    self.end_headers()
                    self.wfile.write(data)
                    return
                with connect(db, True) as con:
                    if path == '/':
                        found = con.execute('SELECT archive_set_id,summary FROM archive_sets ORDER BY archive_set_id').fetchall()
                        body = '<section>' + ''.join(
                            f'<p>{anchor("/set/" + quote(r[0], safe=""), r[0], language)} — {html.escape(r[1])}</p>'
                            for r in found) + '</section>'
                        content = page(tr('home', language), body, language, path)
                    elif path.startswith('/disc/'):
                        identifier = path.removeprefix('/disc/')
                        r = con.execute(IDENTITY_JOIN + ' WHERE disc_id=?', (identifier,)).fetchone()
                        if not r and self.redirect_alias(con, 'disc_aliases', identifier, '/disc/'):
                            return
                        if not r:
                            return self.send_error(404)
                        body = details(dict(r), language) + backup_details(con, r['archive_set_id'], language)
                        m = con.execute('SELECT metadata_json FROM disc_metadata WHERE disc_id=?', (identifier,)).fetchone()
                        if m:
                            metadata = json.loads(m[0])
                            body += details(metadata['values'], language) + details(metadata['targets'], language)
                        summary = con.execute('SELECT summary,restore_status FROM archive_sets WHERE archive_set_id=?', (r['archive_set_id'],)).fetchone()
                        body += details(dict(summary), language)
                        body += content_details(con, identifier, language)
                        body += (f'<section class="notice"><h2>{html.escape(tr("restore", language))}</h2>'
                                 f'<p>{html.escape(tr("restore_note", language))}</p>'
                                 f'<p class="warning">{html.escape(tr("simulation_warning", language))}</p></section>')
                        content = page(identifier, body, language, path)
                    elif path in ('/ids', '/deleted'):
                        counters = con.execute('SELECT * FROM id_counters ORDER BY prefix').fetchall()
                        body = f'<section><p>{html.escape(tr("next_note", language))} {anchor("/deleted", tr("deleted", language), language)}</p>'
                        body += ''.join(
                            f'<p>{html.escape(c["prefix"])} · {tr("used", language)} {c["last_number"]} · {tr("next", language)} BD-{html.escape(c["prefix"])}-{c["next_number"]:04d}</p>'
                            for c in counters) + '</section>'
                        found = con.execute(IDENTITY_JOIN + ' WHERE COALESCE(l.catalog_deleted,0)=? ORDER BY i.disc_index,d.disc_id', (int(path == '/deleted'),)).fetchall()
                        for d in found:
                            body += f'<section>{anchor("/disc/" + quote(d["disc_id"], safe=""), d["disc_id"], language)}'
                            body += f' · {tr("index", language)} {html.escape(str(d["disc_index"] or tr("pending", language)))} · {html.escape(d["volume_label"])}<br>'
                            body += f'{anchor("/volume/" + quote(d["volume_id"], safe=""), d["volume_id"], language)} · {d["volume_index"]}/{d["volume_count"]}</section>'
                        content = page(tr('deleted_title' if path == '/deleted' else 'ids', language), body, language, path)
                    elif path.startswith('/volume/'):
                        identifier = path.removeprefix('/volume/')
                        r = con.execute(IDENTITY_JOIN + ' WHERE i.volume_id=?', (identifier,)).fetchone()
                        if not r:
                            return self.send_error(404)
                        body = details(dict(r), language) + f'<section>{anchor("/disc/" + quote(r["disc_id"], safe=""), tr("open_disc", language), language)}</section>'
                        content = page(identifier, body, language, path)
                    elif path.startswith('/set/'):
                        identifier = path.removeprefix('/set/')
                        r = con.execute('SELECT * FROM archive_sets WHERE archive_set_id=?', (identifier,)).fetchone()
                        if not r and self.redirect_alias(con, 'set_aliases', identifier, '/set/'):
                            return
                        if not r:
                            return self.send_error(404)
                        found = con.execute("SELECT d.disc_id,position,disc_count,location,CASE WHEN l.catalog_deleted=1 THEN 'RECORD_DELETED / ' || status ELSE status END FROM discs d LEFT JOIN disc_lifecycle l USING(disc_id) WHERE archive_set_id=? ORDER BY position", (identifier,)).fetchall()
                        body = details(dict(r), language) + backup_details(con, identifier, language) + '<section>' + ''.join(
                            f'<p>{anchor("/disc/" + quote(d[0], safe=""), d[0], language)} {d[1]}/{d[2]} · {html.escape(d[3])} · {html.escape(d[4])}</p>'
                            for d in found) + '</section>'
                        content = page(identifier, body, language, path)
                    else:
                        return self.send_error(404)
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(content)))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; font-src 'self'; base-uri 'none'; frame-ancestors 'none'")
                self.end_headers()
                self.wfile.write(content)
            except (sqlite3.Error, OSError):
                self.send_error(503, 'Catalog unavailable; run sync first')
    return Handler


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    for name in ('sync','list','serve'):
        p=sub.add_parser(name); p.add_argument('--db',type=Path,required=True)
        if name=='list': p.add_argument('--include-deleted',action='store_true')
        if name=='sync': p.add_argument('--json',type=Path,required=True)
        if name=='serve':
            p.add_argument('--host',default='127.0.0.1'); p.add_argument('--port',type=int,default=8765)
            p.add_argument('--allow-lan',action='store_true',help='Explicitly expose read-only metadata on the LAN')
    args=parser.parse_args()
    if args.command=='sync': print(json.dumps(sync(args.json,args.db),ensure_ascii=True))
    elif args.command=='list': print(json.dumps(rows(args.db,args.include_deleted),ensure_ascii=True,indent=2))
    else:
        if args.host not in ('127.0.0.1','localhost','::1') and not args.allow_lan:
            parser.error('Non-loopback binding requires --allow-lan. Metadata has no authentication.')
        server=ThreadingHTTPServer((args.host,args.port),make_handler(args.db))
        print(f'Catalog: http://{args.host}:{args.port} (read only)',flush=True)
        try: server.serve_forever()
        except KeyboardInterrupt: pass
        finally: server.server_close()

if __name__=='__main__':
    main()
