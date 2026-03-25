-- Migration 10: Dedup support for metric proposals
--
-- Adds an index for efficient dedup queries on metric_proposal_items
-- and stores submission-time metadata (filtered duplicates, warnings)
-- on the proposals envelope.

-- Index for efficient dedup queries
CREATE INDEX IF NOT EXISTS idx_metric_proposal_items_name_status
    ON metric_proposal_items(metric_name, status);

-- Store submission-time metadata on proposals
ALTER TABLE metric_proposals
    ADD COLUMN IF NOT EXISTS filtered_duplicates JSONB DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS submission_warnings JSONB DEFAULT '[]'::jsonb;
