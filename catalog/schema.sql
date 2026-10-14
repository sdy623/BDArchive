PRAGMA foreign_keys=ON;
-- Old NFC URLs redirect to the current record; aliases are never list entries.
CREATE TABLE IF NOT EXISTS disc_aliases (
 old_id TEXT PRIMARY KEY, new_id TEXT NOT NULL REFERENCES discs(disc_id)
);
CREATE TABLE IF NOT EXISTS set_aliases (
 old_id TEXT PRIMARY KEY, new_id TEXT NOT NULL REFERENCES archive_sets(archive_set_id)
);
CREATE TABLE IF NOT EXISTS archive_sets (
 archive_set_id TEXT PRIMARY KEY,
 category TEXT NOT NULL CHECK(category IN ('I','II','III','M')),
 summary TEXT NOT NULL DEFAULT '',
 file_count INTEGER NOT NULL,
 total_bytes INTEGER NOT NULL,
 original_deleted INTEGER NOT NULL DEFAULT 0 CHECK(original_deleted IN (0,1)),
 restore_status TEXT,
 ingest_sha256 TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS discs (
 disc_id TEXT PRIMARY KEY,
 archive_set_id TEXT NOT NULL REFERENCES archive_sets(archive_set_id),
 position INTEGER NOT NULL CHECK(position>0),
 disc_count INTEGER NOT NULL CHECK(disc_count>=position),
 media_type TEXT NOT NULL,
 burn_date TEXT,
 hash TEXT,
 status TEXT NOT NULL,
 location TEXT NOT NULL DEFAULT '',
 nfc_url TEXT NOT NULL,
 original_deleted INTEGER NOT NULL DEFAULT 0,
 registered INTEGER NOT NULL DEFAULT 0,
 verification_status TEXT,
 simulation INTEGER,
 UNIQUE(archive_set_id,position)
);
CREATE TABLE IF NOT EXISTS catalog_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS set_details (
 archive_set_id TEXT PRIMARY KEY REFERENCES archive_sets(archive_set_id),
 details_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS discs_by_set ON discs(archive_set_id);
-- Additive migration: old archive_sets/discs layouts stay readable.
CREATE TABLE IF NOT EXISTS disc_identity (
 disc_id TEXT PRIMARY KEY REFERENCES discs(disc_id),
 catalog_id TEXT,
 disc_index INTEGER UNIQUE CHECK(disc_index>0),
 disc_prefix TEXT NOT NULL,
 disc_number INTEGER NOT NULL CHECK(disc_number>0),
 volume_id TEXT NOT NULL UNIQUE,
 volume_index INTEGER NOT NULL CHECK(volume_index>0),
 volume_count INTEGER NOT NULL CHECK(volume_count>=volume_index),
 volume_label TEXT NOT NULL UNIQUE COLLATE NOCASE,
 filesystem_serial TEXT,
 identity_origin TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS id_counters (
 prefix TEXT PRIMARY KEY,
 last_number INTEGER NOT NULL CHECK(last_number>=0),
 next_number INTEGER NOT NULL CHECK(next_number>last_number)
);

-- Reversible record deletion never erases the identity or verification evidence.
CREATE TABLE IF NOT EXISTS disc_lifecycle (
 disc_id TEXT PRIMARY KEY REFERENCES discs(disc_id),
 catalog_deleted INTEGER NOT NULL DEFAULT 0 CHECK(catalog_deleted IN (0,1)),
 deleted_at TEXT, delete_reason TEXT
);
CREATE TABLE IF NOT EXISTS disc_metadata (
 disc_id TEXT PRIMARY KEY REFERENCES discs(disc_id), metadata_json TEXT NOT NULL
);
