-- Query Memory: ensure cards_sql + card_chunks exist and have workbench columns.
-- Safe to run on fresh installs or existing deployments (all statements are idempotent).

CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Core table for SQL cards (originally from Metabase ingestion, now also workbench)
CREATE TABLE IF NOT EXISTS cards_sql (
  card_id BIGINT PRIMARY KEY,
  title TEXT NOT NULL,
  sql TEXT NOT NULL,
  author_id BIGINT,
  author_name TEXT,
  author_email TEXT,
  collection_id BIGINT,
  collection_path TEXT,
  metabase_url TEXT,
  db_id BIGINT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  template_tags_json JSONB,
  raw_card_json JSONB,
  fingerprint TEXT GENERATED ALWAYS AS (encode(digest(sql, 'sha256'), 'hex')) STORED,
  short_desc TEXT,
  long_desc TEXT
);

ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS sql_identifiers TEXT GENERATED ALWAYS AS (
  regexp_replace(sql, '[^a-zA-Z0-9_\.]+', ' ', 'g')
) STORED;

ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS ts_doc tsvector GENERATED ALWAYS AS (
  setweight(to_tsvector('simple', coalesce(title,'')), 'A') ||
  setweight(to_tsvector('simple', coalesce(short_desc,'')), 'B') ||
  setweight(to_tsvector('simple', coalesce(long_desc,'')), 'C') ||
  setweight(to_tsvector('simple', regexp_replace(coalesce(sql,''), '[^a-zA-Z0-9_\.]+', ' ', 'g')), 'D')
) STORED;

CREATE INDEX IF NOT EXISTS idx_cards_sql_ts ON cards_sql USING GIN (ts_doc);
CREATE INDEX IF NOT EXISTS idx_cards_sql_title_trgm ON cards_sql USING GIN (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_cards_sql_ident_trgm ON cards_sql USING GIN (sql_identifiers gin_trgm_ops);

-- Chunk summaries per card
CREATE TABLE IF NOT EXISTS card_chunks (
  chunk_id BIGSERIAL PRIMARY KEY,
  card_id BIGINT REFERENCES cards_sql(card_id) ON DELETE CASCADE,
  chunk_type TEXT,
  chunk_index INT,
  text TEXT,
  semantic_match BOOLEAN DEFAULT FALSE,
  semantic_score DOUBLE PRECISION,
  signals JSONB
);

CREATE INDEX IF NOT EXISTS idx_card_chunks_card ON card_chunks (card_id, chunk_type, chunk_index);

-- Parsed SQL features per card
CREATE TABLE IF NOT EXISTS card_features (
  card_id BIGINT PRIMARY KEY REFERENCES cards_sql(card_id) ON DELETE CASCADE,
  tables TEXT[],
  columns TEXT[],
  joins JSONB,
  predicates JSONB,
  has_cte BOOLEAN,
  group_by TEXT[],
  time_grain TEXT,
  parameters JSONB,
  subset_tables TEXT[]
);

-- Workbench-specific columns (query memory feature)
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS source VARCHAR(50) DEFAULT 'metabase';
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS org_id UUID;
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS user_question TEXT;
