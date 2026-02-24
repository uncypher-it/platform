-- Node Descriptions Schema for Semantic Search
-- This table stores natural language descriptions of nodes (tables)
-- that will be embedded in Chroma for semantic search

-- Create the table
CREATE TABLE node_descriptions (
    -- Primary identification
    id              BIGSERIAL PRIMARY KEY,
    node_id         BIGINT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    
    -- Content
    description     TEXT NOT NULL CHECK (length(description) >= 10),
    
    -- Chroma reference
    embedding_id    TEXT UNIQUE NOT NULL,
    
    -- Soft delete (CRITICAL for filtering)
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,
    
    -- Audit trail
    created_by      BIGINT REFERENCES users(id),
    updated_by      BIGINT REFERENCES users(id),
    deleted_by      BIGINT REFERENCES users(id),
    created_at      TIMESTAMP NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMP NULL
);

-- Indexes for performance
CREATE INDEX idx_node_descriptions_node_id ON node_descriptions(node_id);
CREATE INDEX idx_node_descriptions_active ON node_descriptions(node_id, is_deleted);
CREATE INDEX idx_node_descriptions_embedding ON node_descriptions(embedding_id);

-- Constraint: Deleted descriptions must have deleted_at timestamp
ALTER TABLE node_descriptions 
ADD CONSTRAINT chk_deleted_timestamp 
CHECK ((is_deleted = false AND deleted_at IS NULL) OR 
       (is_deleted = true AND deleted_at IS NOT NULL));

-- Grant permissions
GRANT SELECT, INSERT, UPDATE ON node_descriptions TO kb;
GRANT USAGE, SELECT ON SEQUENCE node_descriptions_id_seq TO kb;

