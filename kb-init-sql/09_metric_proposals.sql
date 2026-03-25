-- Migration 09: Metric proposal workflow tables
--
-- Two tables for the metric approval flow:
--   metric_proposals       – batch envelope with provenance
--   metric_proposal_items  – individual metric candidates

CREATE TABLE IF NOT EXISTS metric_proposals (
    id              TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    org_id          TEXT NOT NULL,
    source          TEXT NOT NULL,             -- 'sql_analysis', 'manual', 'import'
    source_id       TEXT,                      -- conversation_id, import batch id, etc.
    reasoning       TEXT,
    created_by      TEXT,                      -- user/agent who submitted
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'partial', 'completed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_metric_proposals_org ON metric_proposals(org_id);
CREATE INDEX IF NOT EXISTS idx_metric_proposals_org_status ON metric_proposals(org_id, status);

CREATE TABLE IF NOT EXISTS metric_proposal_items (
    id                  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    proposal_id         TEXT NOT NULL REFERENCES metric_proposals(id) ON DELETE CASCADE,
    metric_name         TEXT NOT NULL,
    display_name        TEXT NOT NULL,
    metric_type         TEXT NOT NULL
                        CHECK (metric_type IN ('simple','derived','cumulative','ratio','conversion')),
    sql_description     TEXT,
    description         TEXT,
    tags                JSONB NOT NULL DEFAULT '[]'::jsonb,
    team_name           TEXT,
    type_params         JSONB NOT NULL DEFAULT '{}'::jsonb,
    dependencies        JSONB NOT NULL DEFAULT '[]'::jsonb,
    connected_tables    JSONB NOT NULL DEFAULT '[]'::jsonb,
    status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'accepted', 'rejected', 'failed')),
    edited_data         JSON,                  -- user's edits before accept (mirrors kb_proposal_actions.edited_data)
    apply_result        JSON,                  -- materialization result for audit (mirrors kb_proposal_actions.apply_result)
    created_metric_id   BIGINT REFERENCES nodes(id),
    actioned_at         TIMESTAMPTZ,           -- when user accepted/rejected (mirrors kb_proposal_actions.actioned_at)
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_metric_proposal_items_proposal ON metric_proposal_items(proposal_id);
CREATE INDEX IF NOT EXISTS idx_metric_proposal_items_status ON metric_proposal_items(proposal_id, status);
