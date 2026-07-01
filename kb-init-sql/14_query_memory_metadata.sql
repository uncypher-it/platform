-- Query memory provenance, tiers, and retirement metadata.
-- Idempotent for existing workbench memory deployments.

ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS memory_tier VARCHAR(32) DEFAULT 'org_canonical';
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS saved_by TEXT;
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS purpose_tag TEXT;
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS retired_at TIMESTAMPTZ;
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS retired_by TEXT;
ALTER TABLE cards_sql ADD COLUMN IF NOT EXISTS retirement_reason TEXT;

UPDATE cards_sql
   SET memory_tier = 'personal_saved'
 WHERE source = 'workbench'
   AND (memory_tier IS NULL OR memory_tier = 'org_canonical');

UPDATE cards_sql
   SET memory_tier = 'org_canonical'
 WHERE memory_tier NOT IN ('personal_saved', 'team_verified', 'org_canonical');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'cards_sql_memory_tier_check'
  ) THEN
    ALTER TABLE cards_sql
      ADD CONSTRAINT cards_sql_memory_tier_check
      CHECK (memory_tier IN ('personal_saved', 'team_verified', 'org_canonical'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_cards_sql_memory_active
  ON cards_sql (org_id, memory_tier, source)
  WHERE retired_at IS NULL;
