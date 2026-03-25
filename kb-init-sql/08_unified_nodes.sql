-- Migration 08: Unified nodes registry + metric support
--
-- Renames nodes.table_name → nodes.name, adds node_type ENUM,
-- creates table_metadata and metric_metadata tables,
-- extends nodes_connection for metric edges (nullable columns).

BEGIN;

-- 1. Create node type enum
DO $$ BEGIN
    CREATE TYPE node_type_enum AS ENUM ('table', 'metric');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 2. Add node_type column with default 'table'
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS node_type node_type_enum NOT NULL DEFAULT 'table';

-- 3. Rename table_name → name
ALTER TABLE nodes RENAME COLUMN table_name TO name;

-- 4. Drop old unique constraint and create new composite unique index
ALTER TABLE nodes DROP CONSTRAINT IF EXISTS nodes_table_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_name_type_org ON nodes(name, node_type, org_id);

-- 5. Update indexes
DROP INDEX IF EXISTS idx_nodes_org_table;
CREATE INDEX IF NOT EXISTS idx_nodes_org_name ON nodes(org_id, name);
CREATE INDEX IF NOT EXISTS idx_nodes_node_type ON nodes(node_type);

-- 6. Create table_metadata
CREATE TABLE IF NOT EXISTS table_metadata (
    id          BIGSERIAL PRIMARY KEY,
    node_id     BIGINT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    table_name  TEXT NOT NULL,
    schema_name TEXT,
    UNIQUE (node_id)
);
CREATE INDEX IF NOT EXISTS idx_table_metadata_node ON table_metadata(node_id);
CREATE INDEX IF NOT EXISTS idx_table_metadata_name ON table_metadata(table_name);

-- 7. Backfill table_metadata from existing table nodes
INSERT INTO table_metadata (node_id, table_name, schema_name)
SELECT id, name, schema_name FROM nodes WHERE node_type = 'table'
ON CONFLICT (node_id) DO NOTHING;

-- 8. Drop schema_name from nodes (now in table_metadata)
ALTER TABLE nodes DROP COLUMN IF EXISTS schema_name;

-- 9. Create metric_metadata
CREATE TABLE IF NOT EXISTS metric_metadata (
    id                  BIGSERIAL PRIMARY KEY,
    node_id             BIGINT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    type                TEXT NOT NULL CHECK (type IN ('simple','derived','cumulative','ratio','conversion')),
    sql_description     TEXT,
    tags                JSONB DEFAULT '[]'::jsonb,
    team_name           TEXT,
    type_params         JSONB DEFAULT '{}'::jsonb,
    last_updated        TIMESTAMPTZ,
    UNIQUE (node_id)
);
CREATE INDEX IF NOT EXISTS idx_metric_metadata_node ON metric_metadata(node_id);
CREATE INDEX IF NOT EXISTS idx_metric_metadata_type ON metric_metadata(type);

-- 10. Extend nodes_connection for metric edges (columns nullable)
ALTER TABLE nodes_connection ALTER COLUMN from_column DROP NOT NULL;
ALTER TABLE nodes_connection ALTER COLUMN to_column DROP NOT NULL;
ALTER TABLE nodes_connection ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

-- 11. Update unique constraint on nodes_connection to handle NULLs
ALTER TABLE nodes_connection DROP CONSTRAINT IF EXISTS nodes_connection_from_node_id_to_node_id_from_column_to_col_key;
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_connection_unique ON nodes_connection (
    from_node_id, to_node_id,
    COALESCE(from_column, ''), COALESCE(to_column, '')
);

COMMIT;
