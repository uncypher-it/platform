-- Migration: Add schema_name column to nodes table
-- This migration adds support for multi-schema table references
-- schema_name is nullable - tables may or may not have a schema specified

-- Add schema_name column (nullable, no default)
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS schema_name TEXT;
