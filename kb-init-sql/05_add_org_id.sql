-- Migration: Add org_id column for multi-tenant organization support
-- This migration adds org_id only to ROOT entities. Child tables inherit org via FK.

-- Add org_id to nodes (ROOT ENTITY - all child tables inherit via FK)
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS org_id UUID;
CREATE INDEX IF NOT EXISTS idx_nodes_org_id ON nodes(org_id);
CREATE INDEX IF NOT EXISTS idx_nodes_org_table ON nodes(org_id, table_name);

-- Add org_id to sessions (STANDALONE ENTITY)
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS org_id UUID;
CREATE INDEX IF NOT EXISTS idx_sessions_org_id ON sessions(org_id);

-- Add org_id to activity_log (STANDALONE AUDIT ENTITY)
ALTER TABLE activity_log ADD COLUMN IF NOT EXISTS org_id UUID;
CREATE INDEX IF NOT EXISTS idx_activity_log_org_id ON activity_log(org_id);

-- NOTE: These tables DO NOT get org_id (they inherit via FK):
-- - node_columns    -> inherits from nodes via node_id FK
-- - column_values   -> inherits from node_columns via node_column_id FK
-- - nodes_connection -> inherits from nodes via from_node_id/to_node_id FK

-- Example queries for child tables by org (use JOINs):
--
-- Get node_columns for an org:
-- SELECT nc.* FROM node_columns nc
-- JOIN nodes n ON nc.node_id = n.id
-- WHERE n.org_id = 'bbdc9a40-3bd8-4cfa-84c2-e2885e32188e';
--
-- Get connections for an org:
-- SELECT nc.* FROM nodes_connection nc
-- JOIN nodes n ON nc.from_node_id = n.id
-- WHERE n.org_id = 'bbdc9a40-3bd8-4cfa-84c2-e2885e32188e';
