-- Knowledge Base Graph Database Schema

-- 1.1 users
CREATE TABLE users (
    id         BIGSERIAL PRIMARY KEY,
    email      TEXT UNIQUE NOT NULL,
    name       TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- 1.2 nodes
CREATE TABLE nodes (
    id            BIGSERIAL PRIMARY KEY,
    table_name    TEXT UNIQUE NOT NULL,
    schema_name   TEXT,
    soft_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at    TIMESTAMP NULL,
    born_v        INT,
    dead_v        INT NULL,
    created_by    BIGINT REFERENCES users(id),
    deleted_by    BIGINT REFERENCES users(id),
    created_at    TIMESTAMP NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP NOT NULL DEFAULT now()
);

-- 1.3 node_columns
CREATE TABLE node_columns (
    id            BIGSERIAL PRIMARY KEY,
    node_id       BIGINT NOT NULL REFERENCES nodes(id),
    column_name   TEXT NOT NULL,
    query_role    TEXT NOT NULL CHECK (query_role IN ('date_filter','filter_condition','display_column')),
    data_type     TEXT,
    soft_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at    TIMESTAMP NULL,
    born_v        INT,
    dead_v        INT NULL,
    created_by    BIGINT REFERENCES users(id),
    deleted_by    BIGINT REFERENCES users(id),
    created_at    TIMESTAMP NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (node_id, column_name)
);

-- 1.4 column_values (MANDATORY for filter_condition columns)
CREATE TABLE column_values (
    id             BIGSERIAL PRIMARY KEY,
    node_column_id BIGINT NOT NULL REFERENCES node_columns(id),
    value          TEXT NOT NULL,
    soft_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at     TIMESTAMP NULL,
    created_by     BIGINT REFERENCES users(id),
    created_at     TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (node_column_id, value)
);

-- 1.5 nodes_connection (edges)
CREATE TABLE nodes_connection (
    id             BIGSERIAL PRIMARY KEY,
    from_node_id   BIGINT NOT NULL REFERENCES nodes(id),
    from_column    TEXT NOT NULL,
    to_node_id     BIGINT NOT NULL REFERENCES nodes(id),
    to_column      TEXT NOT NULL,
    cardinality    TEXT NOT NULL DEFAULT 'N:M'
                   CHECK (cardinality IN ('1:1','1:N','N:1','N:M')),
    weight         NUMERIC NOT NULL DEFAULT 0,
    soft_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at     TIMESTAMP NULL,
    born_v         INT,
    dead_v         INT NULL,
    created_by     BIGINT REFERENCES users(id),
    deleted_by     BIGINT REFERENCES users(id),
    updated_by     BIGINT REFERENCES users(id),
    updated_at     TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (from_node_id, to_node_id, from_column, to_column)
);

-- 1.6 sessions
CREATE TABLE sessions (
    id          UUID PRIMARY KEY,
    user_id     BIGINT REFERENCES users(id),
    version     INT NOT NULL,
    nodes_used  JSONB NOT NULL,
    edges_used  JSONB NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT now(),
    closed_at   TIMESTAMP NULL,
    status      TEXT NOT NULL DEFAULT 'open'
                CHECK (status IN ('open','confirmed','abandoned'))
);

-- 1.7 activity_log
CREATE TABLE activity_log (
    id          BIGSERIAL PRIMARY KEY,
    session_id  UUID REFERENCES sessions(id),
    user_id     BIGINT REFERENCES users(id),
    event_type  TEXT NOT NULL CHECK (event_type IN ('query','confirm','change_set','warning','reward_skip')),
    payload     JSONB NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT now()
);