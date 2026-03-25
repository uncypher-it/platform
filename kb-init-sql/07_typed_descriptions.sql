-- Typed descriptions: add description_type + target_name columns
-- Allows descriptions to target tables, columns, or joins specifically.

ALTER TABLE node_descriptions
ADD COLUMN IF NOT EXISTS description_type TEXT NOT NULL DEFAULT 'table';

ALTER TABLE node_descriptions
DROP CONSTRAINT IF EXISTS chk_description_type;

ALTER TABLE node_descriptions
ADD CONSTRAINT chk_description_type
CHECK (description_type IN ('table', 'column', 'join'));

ALTER TABLE node_descriptions
ADD COLUMN IF NOT EXISTS target_name TEXT;

CREATE INDEX IF NOT EXISTS idx_node_descriptions_type
ON node_descriptions(description_type);

-- Backfill target_name from nodes.table_name for existing rows
UPDATE node_descriptions nd
SET target_name = n.table_name
FROM nodes n
WHERE nd.node_id = n.id AND nd.target_name IS NULL;

ALTER TABLE node_descriptions
ALTER COLUMN target_name SET NOT NULL;
