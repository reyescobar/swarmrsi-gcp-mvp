-- =============================================================================
-- SwarmRSI + Gemma Observer + Harness2/Harbor Schema for AlloyDB PostgreSQL 17
-- Extensions: vector, alloydb_scann (mode='AUTO'), google_ml_integration
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS alloydb_scann;
CREATE EXTENSION IF NOT EXISTS google_ml_integration;

CREATE SCHEMA IF NOT EXISTS swarm;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'swarm_sandbox_ro') THEN
        CREATE ROLE swarm_sandbox_ro LOGIN;
    END IF;
END $$;
ALTER ROLE swarm_sandbox_ro SET default_transaction_read_only = on;
ALTER ROLE swarm_sandbox_ro SET statement_timeout = '5s';
GRANT USAGE ON SCHEMA swarm TO swarm_sandbox_ro;

CREATE TYPE swarm.campaign_status   AS ENUM ('RUNNING', 'ROUND_SYNTHESIS', 'HALTED_SUCCESS', 'BUDGET_EXHAUSTED');
CREATE TYPE swarm.hypothesis_status AS ENUM ('READY', 'LEASED', 'RETAINED_NEEDS_BASE', 'VALIDATED', 'EXHAUSTED');
CREATE TYPE swarm.operator_kind     AS ENUM ('SEED', 'H_MUTATE', 'P_MUTATE', 'REBASE', 'CROSSOVER');
CREATE TYPE swarm.audit_verdict     AS ENUM ('VERIFIED_GAIN', 'FAITHFUL_NO_GAIN', 'UNCREDITED_IMPL_BUG', 'INFRA_ERROR');
CREATE TYPE swarm.entry_kind        AS ENUM ('finding', 'failure', 'hypothesis');
CREATE TYPE swarm.moderation_state  AS ENUM ('PUBLISHED_IMMEDIATE', 'PUBLISHED_MODERATED', 'HELD_ANTI_CONVERGENCE', 'MERGED_DUPLICATE');
CREATE TYPE swarm.maxim_polarity    AS ENUM ('DO', 'AVOID');
CREATE TYPE swarm.maxim_status      AS ENUM ('PROVISIONAL', 'ACTIVE', 'DEPRECATED');

CREATE TABLE IF NOT EXISTS swarm.campaigns (
    campaign_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                   TEXT NOT NULL,
    goal_manifest_uri      TEXT NOT NULL,
    starter_program_id     UUID,
    incumbent_program_id   UUID,
    incumbent_utility      DOUBLE PRECISION,
    target_utility         DOUBLE PRECISION,
    stop_mode              TEXT NOT NULL DEFAULT 'DUAL' CHECK (stop_mode IN ('STOP_ON_PASS', 'HILL_CLIMB', 'DUAL')),
    network_target_mode    TEXT NOT NULL DEFAULT 'NONE' CHECK (network_target_mode IN ('NONE', 'SHARED_STATELESS', 'EPHEMERAL_CLONE_PER_LEASE', 'SERIALIZED_MUTEX')),
    status                 swarm.campaign_status NOT NULL DEFAULT 'RUNNING',
    current_round          INT NOT NULL DEFAULT 1,
    worker_concurrency     INT NOT NULL DEFAULT 4 CHECK (worker_concurrency >= 1),
    speculation_quota_rem  INT NOT NULL DEFAULT 1 CHECK (speculation_quota_rem >= 0),
    token_budget_limit     BIGINT NOT NULL,
    tokens_spent           BIGINT NOT NULL DEFAULT 0,
    halt_reason            TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS swarm.frontier_stats (
    campaign_id            UUID NOT NULL REFERENCES swarm.campaigns(campaign_id) ON DELETE CASCADE,
    frontier_kind          CHAR(1) NOT NULL CHECK (frontier_kind IN ('H', 'P')),
    discounted_n           DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    discounted_gain        DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    discounted_cost        DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    wait_steps             INT NOT NULL DEFAULT 0,
    PRIMARY KEY (campaign_id, frontier_kind)
);

CREATE TABLE IF NOT EXISTS swarm.hypotheses (
    hypothesis_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id            UUID NOT NULL REFERENCES swarm.campaigns(campaign_id) ON DELETE CASCADE,
    parent_hypothesis_id   UUID REFERENCES swarm.hypotheses(hypothesis_id),
    mechanism_family       TEXT NOT NULL,
    statement              TEXT NOT NULL,
    falsifiable_prediction TEXT NOT NULL,
    required_labels        TEXT[] NOT NULL DEFAULT '{}',
    status                 swarm.hypothesis_status NOT NULL DEFAULT 'READY',
    in_frontier_fh         BOOLEAN NOT NULL DEFAULT false,
    priority_score         DOUBLE PRECISION NOT NULL DEFAULT 1.0,
    lease_owner_vm         TEXT,
    lease_token_hash       TEXT,
    lease_expires_at       TIMESTAMPTZ,
    uncredited_bug_count   INT NOT NULL DEFAULT 0,
    faithful_nogain_count  INT NOT NULL DEFAULT 0,
    seeded_by_maxim_ids    UUID[] NOT NULL DEFAULT '{}',
    embedding              vector(768),
    created_round          INT NOT NULL DEFAULT 1,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hypotheses_claim_queue
    ON swarm.hypotheses (campaign_id, priority_score DESC, created_at ASC)
    WHERE status IN ('READY', 'LEASED');

CREATE INDEX IF NOT EXISTS idx_hypotheses_scann
    ON swarm.hypotheses USING scann (embedding vector_cosine_ops) WITH (mode = 'AUTO');

CREATE TABLE IF NOT EXISTS swarm.programs (
    program_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id            UUID NOT NULL REFERENCES swarm.campaigns(campaign_id) ON DELETE CASCADE,
    origin_hypothesis_id   UUID REFERENCES swarm.hypotheses(hypothesis_id),
    parent_program_id      UUID REFERENCES swarm.programs(program_id),
    donor_program_ids      UUID[] NOT NULL DEFAULT '{}' CHECK (cardinality(donor_program_ids) <= 2),
    operator_used          swarm.operator_kind NOT NULL,
    git_patch_gcs_uri      TEXT NOT NULL,
    patch_sha256           CHAR(64) NOT NULL,
    substrate_snapshot_tag TEXT,
    output_sha256          CHAR(64) NOT NULL,
    aggregate_utility      DOUBLE PRECISION NOT NULL,
    subtask_utilities      JSONB NOT NULL DEFAULT '{}'::jsonb,
    mechanism_labels       TEXT[] NOT NULL DEFAULT '{}',
    in_frontier_fp         BOOLEAN NOT NULL DEFAULT false,
    is_valid_execution     BOOLEAN NOT NULL DEFAULT true,
    created_round          INT NOT NULL DEFAULT 1,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS swarm.trials (
    trial_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id            UUID NOT NULL REFERENCES swarm.campaigns(campaign_id) ON DELETE CASCADE,
    round_num              INT NOT NULL,
    hypothesis_id          UUID NOT NULL REFERENCES swarm.hypotheses(hypothesis_id),
    base_program_id        UUID NOT NULL REFERENCES swarm.programs(program_id),
    donor_program_ids      UUID[] NOT NULL DEFAULT '{}',
    result_program_id      UUID REFERENCES swarm.programs(program_id),
    operator_used          swarm.operator_kind NOT NULL,
    worker_vm_id           TEXT NOT NULL,
    runner_harness         TEXT NOT NULL DEFAULT 'pi-mono',
    local_attempts_used    INT NOT NULL DEFAULT 1 CHECK (local_attempts_used BETWEEN 1 AND 4),
    uncached_tokens_tau    BIGINT NOT NULL DEFAULT 0,
    gate1_smoke_ok         BOOLEAN NOT NULL DEFAULT false,
    gate2_ast_reach_ok     BOOLEAN NOT NULL DEFAULT false,
    gate3_output_shift_ok  BOOLEAN NOT NULL DEFAULT false,
    gate4_objective_ok     BOOLEAN NOT NULL DEFAULT false,
    hypothesis_credited    BOOLEAN GENERATED ALWAYS AS (
        gate1_smoke_ok AND gate2_ast_reach_ok AND gate3_output_shift_ok
    ) STORED,
    audit_badge            swarm.audit_verdict NOT NULL,
    utility_delta          DOUBLE PRECISION,
    diagnostics_summary    TEXT NOT NULL DEFAULT '',
    completed_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS swarm.blackboard_threads (
    thread_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id            UUID NOT NULL REFERENCES swarm.campaigns(campaign_id) ON DELETE CASCADE,
    root_hypothesis_id     UUID NOT NULL UNIQUE REFERENCES swarm.hypotheses(hypothesis_id) ON DELETE CASCADE,
    title                  TEXT NOT NULL,
    rolling_summary        TEXT NOT NULL DEFAULT '',
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS swarm.blackboard_entries (
    entry_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id              UUID NOT NULL REFERENCES swarm.blackboard_threads(thread_id) ON DELETE CASCADE,
    campaign_id            UUID NOT NULL REFERENCES swarm.campaigns(campaign_id) ON DELETE CASCADE,
    trial_id               UUID REFERENCES swarm.trials(trial_id),
    round_num              INT NOT NULL,
    entry_kind             swarm.entry_kind NOT NULL,
    audit_badge            swarm.audit_verdict,
    moderation_state       swarm.moderation_state NOT NULL,
    canonical_entry_id     UUID REFERENCES swarm.blackboard_entries(entry_id),
    body                   TEXT NOT NULL CHECK (char_length(body) <= 2048),
    tsv                    tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED,
    embedding              vector(768),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bb_entries_fts   ON swarm.blackboard_entries USING GIN (tsv);
CREATE INDEX IF NOT EXISTS idx_bb_entries_scann ON swarm.blackboard_entries USING scann (embedding vector_cosine_ops) WITH (mode = 'AUTO');

CREATE TABLE IF NOT EXISTS swarm.goal_memory (
    fact_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id            UUID NOT NULL REFERENCES swarm.campaigns(campaign_id) ON DELETE CASCADE,
    fact_statement         TEXT NOT NULL CHECK (char_length(fact_statement) <= 600),
    evidence_trial_ids     UUID[] NOT NULL CHECK (cardinality(evidence_trial_ids) >= 1),
    round_distilled        INT NOT NULL,
    is_active              BOOLEAN NOT NULL DEFAULT true,
    tsv                    tsvector GENERATED ALWAYS AS (to_tsvector('english', fact_statement)) STORED,
    embedding              vector(768),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS swarm.general_maxims (
    maxim_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    origin_campaign_id     UUID REFERENCES swarm.campaigns(campaign_id) ON DELETE SET NULL,
    polarity               swarm.maxim_polarity NOT NULL DEFAULT 'DO',
    maxim_claim            TEXT NOT NULL CHECK (char_length(maxim_claim) <= 600),
    when_applies           TEXT NOT NULL CHECK (char_length(when_applies) <= 600),
    when_not_to_apply      TEXT NOT NULL DEFAULT '' CHECK (char_length(when_not_to_apply) <= 600),
    mechanism_tags         TEXT[] NOT NULL DEFAULT '{}',
    evidence_trial_ids     UUID[] NOT NULL CHECK (cardinality(evidence_trial_ids) >= 1),
    hit_count              INT NOT NULL DEFAULT 1 CHECK (hit_count >= 0),
    attempt_count          INT NOT NULL DEFAULT 1 CHECK (attempt_count >= hit_count AND attempt_count >= 1),
    status                 swarm.maxim_status NOT NULL DEFAULT 'PROVISIONAL',
    tsv                    tsvector GENERATED ALWAYS AS (to_tsvector('english', maxim_claim || ' ' || when_applies)) STORED,
    embedding              vector(768),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_maxims_scann ON swarm.general_maxims USING scann (embedding vector_cosine_ops) WITH (mode = 'AUTO');
CREATE INDEX IF NOT EXISTS idx_maxims_fts   ON swarm.general_maxims USING GIN (tsv);

CREATE OR REPLACE FUNCTION swarm.wilson_lower_bound(hits INT, attempts INT)
RETURNS DOUBLE PRECISION LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN attempts <= 0 THEN 0.0 ELSE (
        (hits::float8 / attempts) + (1.96*1.96)/(2*attempts)
        - 1.96 * sqrt(((hits::float8 / attempts)*(1.0 - hits::float8 / attempts) + (1.96*1.96)/(4*attempts)) / attempts)
    ) / (1.0 + (1.96*1.96)/attempts) END;
$$;

-- Ring 2/3 Registry: Harness2 candidate bundles gated by Cold Harbor (--n-samples 1) Docker checks
CREATE TABLE IF NOT EXISTS swarm.harness_bundles (
    bundle_id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_bundle_id           UUID REFERENCES swarm.harness_bundles(bundle_id),
    version_label              TEXT NOT NULL UNIQUE,
    bundle_gcs_uri             TEXT NOT NULL,
    bundle_sha256              CHAR(64) NOT NULL,
    evolved_skills             TEXT[] NOT NULL DEFAULT '{}',
    evolved_scripts            TEXT[] NOT NULL DEFAULT '{}',
    control_loop_config        JSONB NOT NULL DEFAULT '{}'::jsonb,
    harbor_dataset_ref         TEXT,
    harbor_n_samples           INT NOT NULL DEFAULT 1 CHECK (harbor_n_samples = 1),
    harbor_cold_pass_at_1      DOUBLE PRECISION,
    harbor_baseline_pass_at_1  DOUBLE PRECISION,
    harbor_paired_ci_low       DOUBLE PRECISION,
    status                     TEXT NOT NULL DEFAULT 'PROPOSED_UNTRUSTED' CHECK (status IN (
        'PROPOSED_UNTRUSTED', 'COLD_VALIDATED', 'QUARANTINED_SELF_CONFIRMATION', 'PROMOTED_ACTORTEMPLATE'
    )),
    promoted_actor_template    TEXT,
    CONSTRAINT chk_promoted_requires_cold_pass CHECK (
        status <> 'PROMOTED_ACTORTEMPLATE'
        OR (harbor_cold_pass_at_1 IS NOT NULL AND harbor_paired_ci_low > 0.0 AND promoted_actor_template IS NOT NULL)
    ),
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    validated_at               TIMESTAMPTZ
);

GRANT SELECT ON
    swarm.blackboard_threads,
    swarm.blackboard_entries,
    swarm.goal_memory,
    swarm.general_maxims,
    swarm.programs
TO swarm_sandbox_ro;
