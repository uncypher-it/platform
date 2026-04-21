-- Migration 12: Case-insensitive node lookup index
--
-- Root cause context:
-- The changeset transform layer previously matched node names with a
-- case-sensitive `WHERE name = %s`, causing duplicate table nodes when the KB
-- bulk generator pre-created a lowercase stub from a ref_map key and the
-- agent later submitted the PascalCase canonical name (or vice versa).
-- This created 42 case-duplicate groups on SuperK prod that required an
-- LLM-based merge pass to clean up.
--
-- Fix: changeset_transform / smart_changeset_transform now match with
-- `lower(name) = lower(%s)` scoped by org_id. This migration adds a
-- functional index so those lookups stay cheap.
--
-- IMPORTANT: org_id is the LEADING column, preserving multi-tenant locality.
-- Partial WHERE clause keeps the index tight by excluding soft-deleted rows.

CREATE INDEX IF NOT EXISTS idx_nodes_org_lower_name_type
    ON nodes (org_id, lower(name), node_type)
    WHERE soft_deleted = false;
