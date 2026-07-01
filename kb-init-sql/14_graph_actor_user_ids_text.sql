-- Migration 14: graph audit user columns bigint -> text
--
-- PR #40 moved kb-api auth to tenant-scoped JWTs minted by the main backend.
-- Those tokens carry backend user UUIDs in `sub`, while the original KB graph
-- schema stored audit actor IDs as BIGINT FKs into the legacy local `users`
-- table. Sessions/activity_log were widened in migration 13, but graph writes
-- still use these actor columns when applying KB changes.
--
-- Without this migration, any add_table/add_column/add_value/add_join or
-- node-description write performed by a UUID-authenticated caller can fail with:
--     invalid input syntax for type bigint: "<uuid>"
--
-- This migration keeps existing integer actor IDs by casting them to text and
-- drops obsolete FKs to the legacy local users table.

DO $$
DECLARE
    target record;
    fk record;
BEGIN
    FOR target IN
        SELECT *
        FROM (VALUES
            ('nodes', 'created_by'),
            ('nodes', 'deleted_by'),
            ('node_columns', 'created_by'),
            ('node_columns', 'deleted_by'),
            ('column_values', 'created_by'),
            ('nodes_connection', 'created_by'),
            ('nodes_connection', 'deleted_by'),
            ('nodes_connection', 'updated_by'),
            ('node_descriptions', 'created_by'),
            ('node_descriptions', 'updated_by'),
            ('node_descriptions', 'deleted_by')
        ) AS columns_to_migrate(table_name, column_name)
    LOOP
        FOR fk IN
            SELECT tc.constraint_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
             AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'FOREIGN KEY'
              AND tc.table_schema = 'public'
              AND tc.table_name = target.table_name
              AND kcu.column_name = target.column_name
        LOOP
            EXECUTE format(
                'ALTER TABLE %I DROP CONSTRAINT %I',
                target.table_name,
                fk.constraint_name
            );
        END LOOP;

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = target.table_name
              AND column_name = target.column_name
              AND data_type = 'bigint'
        ) THEN
            EXECUTE format(
                'ALTER TABLE %I ALTER COLUMN %I TYPE TEXT USING %I::text',
                target.table_name,
                target.column_name,
                target.column_name
            );
        END IF;
    END LOOP;
END $$;
