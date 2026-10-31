-- =====================================================================
-- Egyptian Grand Museum (GEM) - PostgreSQL schema v1.2
-- Requires: PostgreSQL 15+, pgvector >= 0.5 (HNSW), citext
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS citext;

-- ---------------------------------------------------------------------
-- 0. Shared types
-- ---------------------------------------------------------------------
CREATE DOMAIN locale_code AS text
    CHECK (VALUE ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

CREATE TYPE approval_status   AS ENUM ('draft', 'in_review', 'approved', 'unpublished');
CREATE TYPE review_status     AS ENUM ('machine_translated', 'in_review', 'reviewed');
CREATE TYPE position_status   AS ENUM ('verified', 'unverified', 'unavailable');
CREATE TYPE safety_outcome    AS ENUM ('allow', 'qualify', 'clarify', 'redirect', 'block');
CREATE TYPE content_type      AS ENUM ('story', 'era', 'artefact', 'place', 'character', 'tour');
CREATE TYPE message_role      AS ENUM ('visitor', 'assistant');
CREATE TYPE input_kind        AS ENUM ('text', 'voice_transcript');
CREATE TYPE run_status        AS ENUM ('ok', 'degraded', 'failed', 'timeout');
CREATE TYPE job_status        AS ENUM ('queued', 'running', 'succeeded', 'failed', 'cancelled');
CREATE TYPE processing_status AS ENUM ('pending', 'processing', 'ready', 'failed');
CREATE TYPE conversation_scope AS ENUM ('none', 'ephemeral', 'saved');

CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 1. Sources
-- ---------------------------------------------------------------------
CREATE TABLE sources (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title             text NOT NULL,
    author            text,
    publisher         text,
    url               text,
    publication_year  integer,
    source_type       text NOT NULL DEFAULT 'other',
    reliability_level text,
    license           text,
    rights_notes      text,
    retrieved_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE source_documents (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id         uuid NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
    title             text NOT NULL,
    locale            locale_code,
    document_type     text,
    file_storage_key  text,
    processing_status processing_status NOT NULL DEFAULT 'pending',
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, source_id)
);
CREATE INDEX ix_source_documents_source ON source_documents(source_id);

-- ---------------------------------------------------------------------
-- 2. Content entities (publication state lives ONLY in approved_content)
-- ---------------------------------------------------------------------
CREATE TABLE eras (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug       text NOT NULL UNIQUE,
    start_year integer,                          -- negative = BCE
    end_year   integer,
    source_id  uuid REFERENCES sources(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (start_year IS NULL OR end_year IS NULL OR start_year <= end_year)
);

CREATE TABLE era_translations (
    era_id        uuid NOT NULL REFERENCES eras(id) ON DELETE CASCADE,
    locale        locale_code NOT NULL,
    name          text NOT NULL,
    summary       text,
    review_status review_status NOT NULL DEFAULT 'in_review',
    reviewed_by   text,
    reviewed_at   timestamptz,
    PRIMARY KEY (era_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE TABLE figures (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug       text NOT NULL UNIQUE,
    birth_year integer,
    death_year integer,
    source_id  uuid REFERENCES sources(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (birth_year IS NULL OR death_year IS NULL OR birth_year <= death_year)
);

CREATE TABLE figure_translations (
    figure_id     uuid NOT NULL REFERENCES figures(id) ON DELETE CASCADE,
    locale        locale_code NOT NULL,
    name          text NOT NULL,
    biography     text,
    review_status review_status NOT NULL DEFAULT 'in_review',
    reviewed_by   text,
    reviewed_at   timestamptz,
    PRIMARY KEY (figure_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE TABLE characters (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug           text NOT NULL UNIQUE,
    figure_id      uuid NOT NULL UNIQUE REFERENCES figures(id),
    era_id         uuid REFERENCES eras(id),
    lifetime_start integer NOT NULL,
    lifetime_end   integer NOT NULL,
    persona_config jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CHECK (lifetime_start <= lifetime_end)
);

CREATE TABLE character_translations (
    character_id   uuid NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
    locale         locale_code NOT NULL,
    display_name   text NOT NULL,
    intro          text,
    roleplay_label text NOT NULL,                -- "educational role-play" notice
    review_status  review_status NOT NULL DEFAULT 'in_review',
    reviewed_by    text,
    reviewed_at    timestamptz,
    PRIMARY KEY (character_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE TABLE stories (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug          text NOT NULL UNIQUE,
    display_order integer NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE story_translations (
    story_id      uuid NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    locale        locale_code NOT NULL,
    title         text NOT NULL,
    body          text NOT NULL,
    review_status review_status NOT NULL DEFAULT 'in_review',
    reviewed_by   text,
    reviewed_at   timestamptz,
    PRIMARY KEY (story_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 3. Map (museum-area discovery map; NO routing / navigation graph)
-- ---------------------------------------------------------------------
CREATE TABLE areas (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                   text NOT NULL UNIQUE,
    area_type              text NOT NULL DEFAULT 'floor'
                               CHECK (area_type IN ('floor', 'outdoor', 'zone')),
    level                  integer,
    floor_plan_storage_key text,
    source_id              uuid REFERENCES sources(id),
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE area_translations (
    area_id       uuid NOT NULL REFERENCES areas(id) ON DELETE CASCADE,
    locale        locale_code NOT NULL,
    name          text NOT NULL,
    description   text,
    review_status review_status NOT NULL DEFAULT 'in_review',
    reviewed_by   text,
    reviewed_at   timestamptz,
    PRIMARY KEY (area_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE TABLE places (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug             text NOT NULL UNIQUE,
    area_id          uuid REFERENCES areas(id),
    category         text NOT NULL,
    room_code        text,
    position_status  position_status NOT NULL DEFAULT 'unavailable',
    map_x            double precision,
    map_y            double precision,
    geometry         jsonb,
    source_id        uuid REFERENCES sources(id),
    visitor_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_xy_pair CHECK ((map_x IS NULL) = (map_y IS NULL)),
    CONSTRAINT chk_position_unavailable CHECK (
        position_status <> 'unavailable'
        OR (map_x IS NULL AND map_y IS NULL AND geometry IS NULL)),
    CONSTRAINT chk_position_verified CHECK (
        position_status <> 'verified'
        OR (source_id IS NOT NULL AND (map_x IS NOT NULL OR geometry IS NOT NULL)))
);
CREATE INDEX ix_places_area ON places(area_id);
CREATE INDEX ix_places_category ON places(category);

CREATE TABLE place_translations (
    place_id            uuid NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    locale              locale_code NOT NULL,
    name                text NOT NULL,
    description         text,
    accessibility_notes text,
    review_status       review_status NOT NULL DEFAULT 'in_review',
    reviewed_by         text,
    reviewed_at         timestamptz,
    PRIMARY KEY (place_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE TABLE place_relations (
    place_id        uuid NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    nearby_place_id uuid NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    relation_type   text NOT NULL DEFAULT 'nearby',
    source_id       uuid REFERENCES sources(id),
    PRIMARY KEY (place_id, nearby_place_id, relation_type),
    CHECK (place_id <> nearby_place_id)
);
CREATE INDEX ix_place_relations_nearby ON place_relations(nearby_place_id);

-- ---------------------------------------------------------------------
-- 4. Artefacts
-- ---------------------------------------------------------------------
CREATE TABLE artefacts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                text NOT NULL UNIQUE,
    place_id            uuid REFERENCES places(id),      -- NULL = location unavailable
    image_storage_key   text,
    image_source_id     uuid REFERENCES sources(id),
    historical_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_artefacts_place ON artefacts(place_id);

CREATE TABLE artefact_translations (
    artefact_id   uuid NOT NULL REFERENCES artefacts(id) ON DELETE CASCADE,
    locale        locale_code NOT NULL,
    title         text NOT NULL,
    description   text,
    review_status review_status NOT NULL DEFAULT 'in_review',
    reviewed_by   text,
    reviewed_at   timestamptz,
    PRIMARY KEY (artefact_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE TABLE artefact_eras (
    artefact_id uuid NOT NULL REFERENCES artefacts(id) ON DELETE CASCADE,
    era_id      uuid NOT NULL REFERENCES eras(id) ON DELETE RESTRICT,
    PRIMARY KEY (artefact_id, era_id)
);
CREATE INDEX ix_artefact_eras_era ON artefact_eras(era_id);

CREATE TABLE artefact_figures (
    artefact_id       uuid NOT NULL REFERENCES artefacts(id) ON DELETE CASCADE,
    figure_id         uuid NOT NULL REFERENCES figures(id) ON DELETE RESTRICT,
    relationship_type text,
    PRIMARY KEY (artefact_id, figure_id)
);
CREATE INDEX ix_artefact_figures_figure ON artefact_figures(figure_id);

-- ---------------------------------------------------------------------
-- 5. Tours
-- ---------------------------------------------------------------------
CREATE TABLE tours (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug             text NOT NULL UNIQUE,
    duration_minutes integer CHECK (duration_minutes > 0),
    difficulty       text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tour_translations (
    tour_id       uuid NOT NULL REFERENCES tours(id) ON DELETE CASCADE,
    locale        locale_code NOT NULL,
    title         text NOT NULL,
    description   text,
    review_status review_status NOT NULL DEFAULT 'in_review',
    reviewed_by   text,
    reviewed_at   timestamptz,
    PRIMARY KEY (tour_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE TABLE tour_stops (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_id          uuid NOT NULL REFERENCES tours(id) ON DELETE CASCADE,
    place_id         uuid NOT NULL REFERENCES places(id),
    artefact_id      uuid REFERENCES artefacts(id),
    stop_order       integer NOT NULL CHECK (stop_order > 0),
    duration_minutes integer CHECK (duration_minutes > 0),
    UNIQUE (id, tour_id),
    UNIQUE (tour_id, stop_order) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX ix_tour_stops_place ON tour_stops(place_id);

CREATE TABLE tour_stop_translations (
    tour_stop_id  uuid NOT NULL REFERENCES tour_stops(id) ON DELETE CASCADE,
    locale        locale_code NOT NULL,
    reason        text NOT NULL,                 -- why this stop is included
    review_status review_status NOT NULL DEFAULT 'in_review',
    reviewed_by   text,
    reviewed_at   timestamptz,
    PRIMARY KEY (tour_stop_id, locale),
    CHECK (review_status <> 'reviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 6. Jobs: the ONLY durable queue (Redis is not a queue in v1)
-- Claim jobs with:
--   UPDATE jobs SET status='running', locked_at=now(), locked_by=:worker, attempts=attempts+1
--   WHERE id = (SELECT id FROM jobs
--               WHERE status='queued' AND available_at <= now()
--               ORDER BY available_at FOR UPDATE SKIP LOCKED LIMIT 1)
--   RETURNING *;
-- ---------------------------------------------------------------------
CREATE TABLE jobs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type        text NOT NULL,               -- embed_content, purge_expired_conversations, ...
    idempotency_key text NOT NULL UNIQUE,
    status          job_status NOT NULL DEFAULT 'queued',
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
    attempts        integer NOT NULL DEFAULT 0,
    max_attempts    integer NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
    available_at    timestamptz NOT NULL DEFAULT now(),
    locked_at       timestamptz,
    locked_by       text,
    completed_at    timestamptz,
    last_error_code text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_jobs_claim ON jobs(available_at) WHERE status = 'queued';

-- ---------------------------------------------------------------------
-- 7. Approved content (single source of truth for publication state)
-- ---------------------------------------------------------------------
CREATE TABLE approved_content (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    content_type     content_type NOT NULL,
    ref_story_id     uuid UNIQUE REFERENCES stories(id),
    ref_era_id       uuid UNIQUE REFERENCES eras(id),
    ref_artefact_id  uuid UNIQUE REFERENCES artefacts(id),
    ref_place_id     uuid UNIQUE REFERENCES places(id),
    ref_character_id uuid UNIQUE REFERENCES characters(id),
    ref_tour_id      uuid UNIQUE REFERENCES tours(id),
    museum_scope     text NOT NULL DEFAULT 'gem',
    era_id           uuid REFERENCES eras(id),
    approval_status  approval_status NOT NULL DEFAULT 'draft',
    owner_name       text NOT NULL,
    reviewer_name    text,
    version          integer NOT NULL DEFAULT 1 CHECK (version > 0),
    approved_at      timestamptz,
    unpublished_at   timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_exactly_one_ref CHECK (
        num_nonnulls(ref_story_id, ref_era_id, ref_artefact_id,
                     ref_place_id, ref_character_id, ref_tour_id) = 1),
    CONSTRAINT chk_ref_matches_type CHECK (
        CASE content_type
            WHEN 'story'     THEN ref_story_id IS NOT NULL
            WHEN 'era'       THEN ref_era_id IS NOT NULL
            WHEN 'artefact'  THEN ref_artefact_id IS NOT NULL
            WHEN 'place'     THEN ref_place_id IS NOT NULL
            WHEN 'character' THEN ref_character_id IS NOT NULL
            WHEN 'tour'      THEN ref_tour_id IS NOT NULL
        END),
    CONSTRAINT chk_approved_has_reviewer CHECK (
        approval_status <> 'approved'
        OR (reviewer_name IS NOT NULL AND approved_at IS NOT NULL))
);
CREATE INDEX ix_approved_content_filter
    ON approved_content(approval_status, museum_scope, era_id);

-- ---------------------------------------------------------------------
-- 8. Review history (append-only) + automatic logging
-- Actor for the log comes from the session: SET LOCAL app.actor = 'Dr. Name';
-- ---------------------------------------------------------------------
CREATE TABLE content_reviews (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    content_id      uuid NOT NULL REFERENCES approved_content(id) ON DELETE RESTRICT,
    content_version integer NOT NULL,
    from_status     approval_status,
    to_status       approval_status NOT NULL,
    reviewer_name   text NOT NULL,
    note            text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_content_reviews_content ON content_reviews(content_id, created_at);

CREATE FUNCTION trg_reject_modification() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION '% is append-only (% rejected)', TG_TABLE_NAME, TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER content_reviews_append_only
    BEFORE UPDATE OR DELETE ON content_reviews
    FOR EACH ROW EXECUTE FUNCTION trg_reject_modification();
CREATE TRIGGER content_reviews_no_truncate
    BEFORE TRUNCATE ON content_reviews
    FOR EACH STATEMENT EXECUTE FUNCTION trg_reject_modification();
-- At deploy time also: REVOKE UPDATE, DELETE, TRUNCATE ON content_reviews FROM app_role;

CREATE FUNCTION trg_log_content_review() RETURNS trigger AS $$
BEGIN
    INSERT INTO content_reviews (content_id, content_version, from_status, to_status, reviewer_name, note)
    VALUES (NEW.id, NEW.version,
            CASE WHEN TG_OP = 'UPDATE' THEN OLD.approval_status END,
            NEW.approval_status,
            COALESCE(NULLIF(current_setting('app.actor', true), ''), 'system'),
            NULLIF(current_setting('app.note', true), ''));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 9. RAG chunks (pgvector only)
-- ---------------------------------------------------------------------
CREATE TABLE content_chunks (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    content_id         uuid NOT NULL REFERENCES approved_content(id) ON DELETE CASCADE,
    content_version    integer NOT NULL,
    source_id          uuid NOT NULL REFERENCES sources(id),
    source_document_id uuid,                     -- NULL for curator-authored text without a file
    locale             locale_code NOT NULL,
    chunk_index        integer NOT NULL,
    chunk_text         text NOT NULL,
    page_number        integer,
    -- Policy A: ALWAYS copied by trigger from the translation; callers cannot set it.
    review_status      review_status NOT NULL DEFAULT 'in_review',
    -- DIMENSION IS A PLACEHOLDER: set after choosing the Arabic+English embedding model.
    embedding          vector(1024) NOT NULL,
    embedding_model    text NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (content_id, locale, chunk_index),
    FOREIGN KEY (source_document_id, source_id)
        REFERENCES source_documents (id, source_id)
);
CREATE INDEX ix_content_chunks_locale_content ON content_chunks(locale, content_id);
CREATE INDEX ix_content_chunks_embedding
    ON content_chunks USING hnsw (embedding vector_cosine_ops);

-- Review status of the translation that matches a content row + locale.
CREATE FUNCTION content_translation_status(p_content uuid, p_locale locale_code)
RETURNS review_status AS $$
    SELECT CASE ac.content_type
        WHEN 'story'     THEN (SELECT t.review_status FROM story_translations t
                               WHERE t.story_id = ac.ref_story_id AND t.locale = p_locale)
        WHEN 'era'       THEN (SELECT t.review_status FROM era_translations t
                               WHERE t.era_id = ac.ref_era_id AND t.locale = p_locale)
        WHEN 'artefact'  THEN (SELECT t.review_status FROM artefact_translations t
                               WHERE t.artefact_id = ac.ref_artefact_id AND t.locale = p_locale)
        WHEN 'place'     THEN (SELECT t.review_status FROM place_translations t
                               WHERE t.place_id = ac.ref_place_id AND t.locale = p_locale)
        WHEN 'character' THEN (SELECT t.review_status FROM character_translations t
                               WHERE t.character_id = ac.ref_character_id AND t.locale = p_locale)
        WHEN 'tour'      THEN (SELECT t.review_status FROM tour_translations t
                               WHERE t.tour_id = ac.ref_tour_id AND t.locale = p_locale)
    END
    FROM approved_content ac WHERE ac.id = p_content;
$$ LANGUAGE sql STABLE;

-- Chunks: only for APPROVED content at its CURRENT version, and only for locales
-- that have a translation. review_status is taken from that translation.
CREATE FUNCTION trg_chunk_guard() RETURNS trigger AS $$
DECLARE
    ac approved_content%ROWTYPE;
    st review_status;
BEGIN
    SELECT * INTO ac FROM approved_content WHERE id = NEW.content_id;
    IF NOT FOUND OR ac.approval_status <> 'approved' OR ac.version <> NEW.content_version THEN
        RAISE EXCEPTION 'content % is not approved at version %', NEW.content_id, NEW.content_version;
    END IF;
    st := content_translation_status(NEW.content_id, NEW.locale);
    IF st IS NULL THEN
        RAISE EXCEPTION 'content % has no % translation', NEW.content_id, NEW.locale;
    END IF;
    NEW.review_status := st;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER chunk_guard
    BEFORE INSERT OR UPDATE OF content_id, content_version, locale, review_status ON content_chunks
    FOR EACH ROW EXECUTE FUNCTION trg_chunk_guard();

-- Leaving 'approved' always bumps the version (so a re-approval gets a fresh embed job);
-- any version change or withdrawal deletes the old chunks immediately.
CREATE FUNCTION trg_content_changed_before() RETURNS trigger AS $$
BEGIN
    IF OLD.approval_status = 'approved' AND NEW.approval_status <> 'approved'
       AND NEW.version = OLD.version THEN
        NEW.version := OLD.version + 1;
    END IF;
    IF OLD.approval_status = 'approved' AND NEW.approval_status <> 'approved'
       OR NEW.version <> OLD.version THEN
        DELETE FROM content_chunks WHERE content_id = NEW.id;
    END IF;
    IF NEW.approval_status = 'unpublished' AND OLD.approval_status <> 'unpublished' THEN
        NEW.unpublished_at := now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER content_changed_before
    BEFORE UPDATE OF approval_status, version ON approved_content
    FOR EACH ROW EXECUTE FUNCTION trg_content_changed_before();

CREATE FUNCTION trg_content_enqueue_embed() RETURNS trigger AS $$
DECLARE needs boolean;
BEGIN
    IF NEW.approval_status <> 'approved' THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'INSERT' THEN
        needs := true;
    ELSE
        needs := OLD.approval_status <> 'approved' OR OLD.version <> NEW.version;
    END IF;
    IF needs THEN
        INSERT INTO jobs (job_type, idempotency_key, payload)
        VALUES ('embed_content',
                NEW.id::text || ':' || NEW.version::text,
                jsonb_build_object('content_id', NEW.id, 'version', NEW.version))
        ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER content_enqueue_embed
    AFTER INSERT OR UPDATE OF approval_status, version ON approved_content
    FOR EACH ROW EXECUTE FUNCTION trg_content_enqueue_embed();

CREATE TRIGGER content_log_insert
    AFTER INSERT ON approved_content
    FOR EACH ROW EXECUTE FUNCTION trg_log_content_review();
CREATE TRIGGER content_log_status
    AFTER UPDATE OF approval_status ON approved_content
    FOR EACH ROW WHEN (OLD.approval_status IS DISTINCT FROM NEW.approval_status)
    EXECUTE FUNCTION trg_log_content_review();

-- ---------------------------------------------------------------------
-- 10. Fail-safe auto-withdrawal: ANY real change to the data behind approved
-- content sends it back to 'in_review' with version+1 (chunks are deleted by
-- the trigger above). Direct UPDATEs can therefore never leave stale chunks.
-- ---------------------------------------------------------------------
CREATE FUNCTION withdraw_content_for(p_type content_type, p_ref uuid) RETURNS void AS $$
BEGIN
    IF p_ref IS NULL THEN RETURN; END IF;
    PERFORM set_config('app.note', 'auto-withdrawn: underlying content changed', true);
    UPDATE approved_content ac
    SET approval_status = 'in_review', version = ac.version + 1
    WHERE ac.approval_status = 'approved'
      AND ac.content_type = p_type
      AND COALESCE(ac.ref_story_id, ac.ref_era_id, ac.ref_artefact_id,
                   ac.ref_place_id, ac.ref_character_id, ac.ref_tour_id) = p_ref;
    PERFORM set_config('app.note', '', true);
END;
$$ LANGUAGE plpgsql;

-- Trigger args: (content_type, column holding the owning entity's id)
CREATE FUNCTION trg_withdraw_on_change() RETURNS trigger AS $$
DECLARE
    old_j jsonb;
    new_j jsonb;
    ref   uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        old_j := to_jsonb(OLD) - 'updated_at';
        new_j := to_jsonb(NEW) - 'updated_at';
        IF old_j = new_j THEN RETURN NULL; END IF;   -- no real change
        ref := (new_j ->> TG_ARGV[1])::uuid;
    ELSIF TG_OP = 'DELETE' THEN
        ref := (to_jsonb(OLD) ->> TG_ARGV[1])::uuid;
    ELSE
        ref := (to_jsonb(NEW) ->> TG_ARGV[1])::uuid;
    END IF;
    PERFORM withdraw_content_for(TG_ARGV[0]::content_type, ref);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- translations
CREATE TRIGGER withdraw_story_tr AFTER INSERT OR UPDATE OR DELETE ON story_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('story', 'story_id');
CREATE TRIGGER withdraw_era_tr AFTER INSERT OR UPDATE OR DELETE ON era_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('era', 'era_id');
CREATE TRIGGER withdraw_artefact_tr AFTER INSERT OR UPDATE OR DELETE ON artefact_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('artefact', 'artefact_id');
CREATE TRIGGER withdraw_place_tr AFTER INSERT OR UPDATE OR DELETE ON place_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('place', 'place_id');
CREATE TRIGGER withdraw_character_tr AFTER INSERT OR UPDATE OR DELETE ON character_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('character', 'character_id');
CREATE TRIGGER withdraw_tour_tr AFTER INSERT OR UPDATE OR DELETE ON tour_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('tour', 'tour_id');

-- base entities
CREATE TRIGGER withdraw_story AFTER UPDATE ON stories
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('story', 'id');
CREATE TRIGGER withdraw_era AFTER UPDATE ON eras
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('era', 'id');
CREATE TRIGGER withdraw_artefact AFTER UPDATE ON artefacts
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('artefact', 'id');
CREATE TRIGGER withdraw_place AFTER UPDATE ON places
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('place', 'id');
CREATE TRIGGER withdraw_character AFTER UPDATE ON characters
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('character', 'id');
CREATE TRIGGER withdraw_tour AFTER UPDATE ON tours
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('tour', 'id');

-- link tables owned by an entity
CREATE TRIGGER withdraw_artefact_eras AFTER INSERT OR UPDATE OR DELETE ON artefact_eras
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('artefact', 'artefact_id');
CREATE TRIGGER withdraw_artefact_figures AFTER INSERT OR UPDATE OR DELETE ON artefact_figures
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('artefact', 'artefact_id');
CREATE TRIGGER withdraw_place_relations AFTER INSERT OR UPDATE OR DELETE ON place_relations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('place', 'place_id');
CREATE TRIGGER withdraw_tour_stops AFTER INSERT OR UPDATE OR DELETE ON tour_stops
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_on_change('tour', 'tour_id');

-- tour_stop_translations -> owning tour
CREATE FUNCTION trg_withdraw_tour_stop_tr() RETURNS trigger AS $$
DECLARE
    stop_id uuid;
    t_id uuid;
BEGIN
    stop_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.tour_stop_id ELSE NEW.tour_stop_id END;
    IF TG_OP = 'UPDATE'
       AND to_jsonb(OLD) - 'updated_at' = to_jsonb(NEW) - 'updated_at' THEN
        RETURN NULL;
    END IF;
    SELECT tour_id INTO t_id FROM tour_stops WHERE id = stop_id;
    PERFORM withdraw_content_for('tour', t_id);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER withdraw_tour_stop_tr AFTER INSERT OR UPDATE OR DELETE ON tour_stop_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_tour_stop_tr();

-- figure data feeds the character that is based on the figure
CREATE FUNCTION trg_withdraw_figure() RETURNS trigger AS $$
DECLARE
    fid uuid;
    cid uuid;
BEGIN
    IF TG_OP = 'UPDATE'
       AND to_jsonb(OLD) - 'updated_at' = to_jsonb(NEW) - 'updated_at' THEN
        RETURN NULL;
    END IF;
    IF TG_TABLE_NAME = 'figures' THEN
        fid := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
    ELSE
        fid := CASE WHEN TG_OP = 'DELETE' THEN OLD.figure_id ELSE NEW.figure_id END;
    END IF;
    SELECT id INTO cid FROM characters WHERE figure_id = fid;
    PERFORM withdraw_content_for('character', cid);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER withdraw_figures AFTER UPDATE ON figures
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_figure();
CREATE TRIGGER withdraw_figure_tr AFTER INSERT OR UPDATE OR DELETE ON figure_translations
    FOR EACH ROW EXECUTE FUNCTION trg_withdraw_figure();

-- ---------------------------------------------------------------------
-- 11. Accounts and saved state
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_subject_id text UNIQUE,
    email               citext UNIQUE,
    locale_preference   locale_code,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz
);
-- Hard delete = DELETE FROM accounts (cascades to everything owned by the account).
-- Grace period / identity-provider deletion are product decisions.

CREATE TABLE saved_places (
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    place_id   uuid NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    saved_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, place_id)
);

CREATE TABLE saved_artefacts (
    account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    artefact_id uuid NOT NULL REFERENCES artefacts(id) ON DELETE CASCADE,
    saved_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, artefact_id)
);

CREATE TABLE saved_tours (
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    tour_id    uuid NOT NULL REFERENCES tours(id) ON DELETE CASCADE,
    saved_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, tour_id)
);

CREATE TABLE tour_progress (
    account_id      uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    tour_id         uuid NOT NULL REFERENCES tours(id) ON DELETE CASCADE,
    current_stop_id uuid,
    status          text NOT NULL DEFAULT 'in_progress'
                        CHECK (status IN ('in_progress', 'completed')),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, tour_id),
    FOREIGN KEY (current_stop_id, tour_id)
        REFERENCES tour_stops (id, tour_id) ON DELETE SET NULL (current_stop_id)
);

CREATE TABLE tour_progress_stops (
    account_id   uuid NOT NULL,
    tour_id      uuid NOT NULL,
    stop_id      uuid NOT NULL,
    completed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, tour_id, stop_id),
    FOREIGN KEY (account_id, tour_id)
        REFERENCES tour_progress (account_id, tour_id) ON DELETE CASCADE,
    FOREIGN KEY (stop_id, tour_id)
        REFERENCES tour_stops (id, tour_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 12. Saved conversations ONLY (ephemeral conversations live in Redis only)
-- ---------------------------------------------------------------------
CREATE TABLE conversations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    character_id    uuid REFERENCES characters(id),
    locale          locale_code NOT NULL,
    retention_until timestamptz,                 -- NULL = keep until the visitor deletes it
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_conversations_account ON conversations(account_id, created_at DESC);
CREATE INDEX ix_conversations_retention ON conversations(retention_until)
    WHERE retention_until IS NOT NULL;

CREATE TABLE conversation_turns (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role            message_role NOT NULL,
    input           input_kind NOT NULL DEFAULT 'text',
    content         text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_conversation_turns_conv ON conversation_turns(conversation_id, created_at);

-- Citations are SNAPSHOTS: they survive chunk deletion/re-indexing, so old
-- conversations keep their exact references. chunk_id/content_id are informational.
CREATE TABLE turn_sources (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id            uuid NOT NULL REFERENCES conversation_turns(id) ON DELETE CASCADE,
    position           integer NOT NULL,
    source_id          uuid NOT NULL REFERENCES sources(id),
    source_document_id uuid,
    page_number        integer,
    citation_label     text NOT NULL,            -- label shown to the visitor
    content_id         uuid REFERENCES approved_content(id) ON DELETE SET NULL,
    content_version    integer,
    chunk_id           uuid,                     -- NO FK on purpose (chunks are replaced on re-index)
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (turn_id, position),
    FOREIGN KEY (source_document_id, source_id)
        REFERENCES source_documents (id, source_id)
);
CREATE INDEX ix_turn_sources_source ON turn_sources(source_id);

CREATE FUNCTION purge_expired_conversations() RETURNS integer AS $$
DECLARE n integer;
BEGIN
    DELETE FROM conversations
    WHERE retention_until IS NOT NULL AND retention_until < now();
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 13. Agent / audit boundary (metadata only)
-- ---------------------------------------------------------------------
CREATE TABLE agent_runs (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id         uuid NOT NULL UNIQUE,
    trace_id           text NOT NULL,
    conversation_id    uuid,                     -- NO FK: may be an ephemeral (Redis-only) conversation
    conversation_scope conversation_scope NOT NULL DEFAULT 'none',
    locale             locale_code,
    intent             text,
    status             run_status NOT NULL DEFAULT 'ok',
    safety_outcome     safety_outcome,
    contract_version   text NOT NULL,
    latency_ms         integer,
    prompt_tokens      integer,
    completion_tokens  integer,
    error_code         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK ((conversation_scope = 'none') = (conversation_id IS NULL))
);
CREATE INDEX ix_agent_runs_trace ON agent_runs(trace_id);
CREATE INDEX ix_agent_runs_created ON agent_runs(created_at);

CREATE TABLE agent_run_steps (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_run_id     uuid NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
    step_order       integer NOT NULL,
    capability       text NOT NULL CHECK (capability IN (
                         'concierge', 'map_explorer', 'era_historian',
                         'character_guide', 'tour_planner', 'safety_guard')),
    contract_version text NOT NULL,
    status           run_status NOT NULL DEFAULT 'ok',
    safety_outcome   safety_outcome,
    source_ids       uuid[] NOT NULL DEFAULT '{}',   -- audit trail only; array by design
    latency_ms       integer,
    error_code       text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (agent_run_id, step_order)
);

-- ---------------------------------------------------------------------
-- 14. updated_at triggers (base tables only)
-- ---------------------------------------------------------------------
DO $$
DECLARE t record;
BEGIN
    FOR t IN
        SELECT c.table_name FROM information_schema.columns c
        JOIN information_schema.tables tb
          ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
        WHERE c.table_schema = 'public' AND c.column_name = 'updated_at'
          AND tb.table_type = 'BASE TABLE'
    LOOP
        EXECUTE format(
            'CREATE TRIGGER set_updated_at BEFORE UPDATE ON %I
             FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t.table_name);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 15. Public views: approved content + reviewed translations ONLY.
-- The application reads these (never the base tables) for visitor-facing pages.
-- ---------------------------------------------------------------------
CREATE VIEW public_stories AS
SELECT s.id, s.slug, s.display_order, t.locale, t.title, t.body, ac.version
FROM stories s
JOIN approved_content ac ON ac.ref_story_id = s.id AND ac.approval_status = 'approved'
JOIN story_translations t ON t.story_id = s.id AND t.review_status = 'reviewed';

CREATE VIEW public_eras AS
SELECT e.id, e.slug, e.start_year, e.end_year, t.locale, t.name, t.summary, ac.version
FROM eras e
JOIN approved_content ac ON ac.ref_era_id = e.id AND ac.approval_status = 'approved'
JOIN era_translations t ON t.era_id = e.id AND t.review_status = 'reviewed';

CREATE VIEW public_artefacts AS
SELECT a.id, a.slug, a.place_id, a.image_storage_key, t.locale, t.title, t.description, ac.version
FROM artefacts a
JOIN approved_content ac ON ac.ref_artefact_id = a.id AND ac.approval_status = 'approved'
JOIN artefact_translations t ON t.artefact_id = a.id AND t.review_status = 'reviewed';

CREATE VIEW public_places AS
SELECT p.id, p.slug, p.area_id, p.category, p.room_code, p.position_status,
       p.map_x, p.map_y, p.geometry, t.locale, t.name, t.description,
       t.accessibility_notes, ac.version
FROM places p
JOIN approved_content ac ON ac.ref_place_id = p.id AND ac.approval_status = 'approved'
JOIN place_translations t ON t.place_id = p.id AND t.review_status = 'reviewed';

CREATE VIEW public_characters AS
SELECT c.id, c.slug, c.era_id, c.lifetime_start, c.lifetime_end,
       t.locale, t.display_name, t.intro, t.roleplay_label, ac.version
FROM characters c
JOIN approved_content ac ON ac.ref_character_id = c.id AND ac.approval_status = 'approved'
JOIN character_translations t ON t.character_id = c.id AND t.review_status = 'reviewed';

CREATE VIEW public_tours AS
SELECT tr.id, tr.slug, tr.duration_minutes, tr.difficulty, t.locale, t.title, t.description, ac.version
FROM tours tr
JOIN approved_content ac ON ac.ref_tour_id = tr.id AND ac.approval_status = 'approved'
JOIN tour_translations t ON t.tour_id = tr.id AND t.review_status = 'reviewed';

-- Illustrative retrieval (parameterize in the application):
--   SELECT cc.id, cc.content_id, cc.chunk_text, cc.source_id, cc.source_document_id, cc.page_number
--   FROM content_chunks cc
--   JOIN approved_content ac ON ac.id = cc.content_id
--   WHERE ac.approval_status = 'approved'
--     AND cc.content_version = ac.version
--     AND ac.museum_scope = :museum_scope
--     AND cc.locale = :locale
--     AND cc.review_status = 'reviewed'
--     AND (:era_id IS NULL OR ac.era_id = :era_id)
--   ORDER BY cc.embedding <=> :query_embedding
--   LIMIT 5;

COMMIT;