-- D1 metadata for E2EE sync. One row per account. NO health data ever — only the opaque account id, the HLC
-- version (as the client's `packed` string, which sorts in HLC order), a timestamp, and the writing device.
CREATE TABLE IF NOT EXISTS blobs (
  account_id  TEXT PRIMARY KEY,   -- hex(SHA-256("<provider>:<sub>")) — same as the client derives
  version     TEXT NOT NULL,      -- HLC.packed (lexicographically sortable == HLC order)
  envelope    TEXT NOT NULL,      -- the encrypted Envelope JSON (ciphertext only — server can't read it)
  updated_at  INTEGER NOT NULL,   -- server receive time (unix seconds)
  device_id   TEXT NOT NULL       -- which device wrote this version
);
