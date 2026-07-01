-- Migration 13: sessions.user_id AND activity_log.user_id bigint -> text
--
-- Background. Before PR #40 (tenant-scoped JWT auth), kb-api ran with its
-- own local `users` table (bigint id). Both `sessions.user_id` and
-- `activity_log.user_id` were FKs into that table (see 01_schema.sql:77
-- and 01_schema.sql:93).
--
-- After PR #40 the caller passes the main backend's user UUID via the
-- kb-token. Inserting that UUID string into a `bigint` column fails with
--     invalid input syntax for type bigint: "2f8cf82f-31ef-..."
-- The app layer swallows these but the rows are never written (only the
-- Redis session survives). The Postgres row is the fallback when Redis
-- TTL expires for sessions, and activity_log is the only long-term audit.
--
-- This migration widens BOTH columns to TEXT so they accept both legacy
-- integer ids and tenant-scoped UUIDs. FKs to legacy `users` are dropped
-- because the caller's identity now lives in the backend's `users` table,
-- not the KB-local one.
--
-- Idempotent: guards check current state before altering so this file can
-- be run repeatedly and left in the init/ directory for fresh customer
-- deploys.

DO $$
BEGIN
    -- sessions.user_id --------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'sessions'
          AND constraint_name = 'sessions_user_id_fkey'
          AND constraint_type = 'FOREIGN KEY'
    ) THEN
        ALTER TABLE sessions DROP CONSTRAINT sessions_user_id_fkey;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sessions'
          AND column_name = 'user_id'
          AND data_type = 'bigint'
    ) THEN
        ALTER TABLE sessions ALTER COLUMN user_id TYPE TEXT USING user_id::text;
    END IF;

    -- activity_log.user_id ----------------------------------------------
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'activity_log'
          AND constraint_name = 'activity_log_user_id_fkey'
          AND constraint_type = 'FOREIGN KEY'
    ) THEN
        ALTER TABLE activity_log DROP CONSTRAINT activity_log_user_id_fkey;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'activity_log'
          AND column_name = 'user_id'
          AND data_type = 'bigint'
    ) THEN
        ALTER TABLE activity_log ALTER COLUMN user_id TYPE TEXT USING user_id::text;
    END IF;
END $$;
