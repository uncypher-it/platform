-- Phase 2: per-value context for column_values.
--
-- Adds optional enrichment columns so add_value actions can carry their own
-- rationale (description), supporting evidence (evidence_query_ids), and a
-- provenance marker (created_by_action_type, e.g. 'agent_discovery') without
-- needing a heavy node_descriptions row per value.
--
-- Strictly additive and idempotent: every statement is ADD COLUMN IF NOT EXISTS.
-- No data backfill and no constraints that could fail on existing rows. All
-- three columns are nullable, so existing add_value writes remain valid.
-- Paired with startup migration 003_column_values_enrichment for existing DBs.

ALTER TABLE column_values
  ADD COLUMN IF NOT EXISTS description TEXT,
  ADD COLUMN IF NOT EXISTS evidence_query_ids TEXT[],
  ADD COLUMN IF NOT EXISTS created_by_action_type TEXT;
