-- Adds intent + why_md + how_md columns to KB metadata tables for the v3 harness.
ALTER TABLE metric_metadata
  ADD COLUMN IF NOT EXISTS intent VARCHAR(16) DEFAULT 'reference'
    CHECK (intent IN ('reference','project','feedback','user')),
  ADD COLUMN IF NOT EXISTS why_md TEXT,
  ADD COLUMN IF NOT EXISTS how_md TEXT;
ALTER TABLE node_descriptions
  ADD COLUMN IF NOT EXISTS intent VARCHAR(16) DEFAULT 'reference'
    CHECK (intent IN ('reference','project','feedback','user')),
  ADD COLUMN IF NOT EXISTS why_md TEXT,
  ADD COLUMN IF NOT EXISTS how_md TEXT;
-- For feedback/project intents, why_md and how_md should be present (enforced app-layer, see 7a.2).
