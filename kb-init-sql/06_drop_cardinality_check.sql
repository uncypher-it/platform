-- Drop the cardinality CHECK constraint so the agent can send any string
-- (e.g. 'many_to_one') instead of only '1:1','1:N','N:1','N:M'.
ALTER TABLE nodes_connection DROP CONSTRAINT IF EXISTS nodes_connection_cardinality_check;
