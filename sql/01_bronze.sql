-- =====================================================================
-- BRONZE : payload brut de l'API Melodi, immuable, INSERT seul.
-- Objectif : pouvoir rejouer Silver et Gold sans rappeler l'API.
-- =====================================================================

SET search_path TO bronze;

DROP TABLE IF EXISTS bronze.br_melodi_payload;

CREATE TABLE bronze.br_melodi_payload (
    id_payload            BIGSERIAL PRIMARY KEY,
    id_execution          VARCHAR(36)  NOT NULL,
    dataset_id            VARCHAR(100) NOT NULL,
    niveau_interroge      VARCHAR(10)  NOT NULL,   -- FRANCE / REG / DEP / COM
    code_interroge        VARCHAR(20),             -- NULL si pas de filtre GEO
    numero_page           INTEGER      NOT NULL,
    url_appelee           TEXT         NOT NULL,
    code_http             INTEGER,
    latence_ms            BIGINT,
    nb_observations_page  INTEGER,
    est_derniere_page     BOOLEAN,
    payload_json          JSONB        NOT NULL,
    date_ingestion        TIMESTAMP    NOT NULL DEFAULT now()
);

COMMENT ON TABLE  bronze.br_melodi_payload IS 'Une ligne par page d API. Jamais d UPDATE ni de DELETE.';
COMMENT ON COLUMN bronze.br_melodi_payload.payload_json IS 'Reponse JSON complete, telle que recue';
COMMENT ON COLUMN bronze.br_melodi_payload.est_derniere_page IS 'paging.isLast de la reponse';

CREATE INDEX idx_br_execution ON bronze.br_melodi_payload (id_execution);
CREATE INDEX idx_br_niveau_page ON bronze.br_melodi_payload (niveau_interroge, numero_page);

-- Garde-fou : le Bronze est immuable.
CREATE OR REPLACE FUNCTION bronze.fn_bronze_immuable() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Le schema bronze est immuable : ni UPDATE ni DELETE autorises.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bronze_immuable
    BEFORE UPDATE OR DELETE ON bronze.br_melodi_payload
    FOR EACH ROW EXECUTE FUNCTION bronze.fn_bronze_immuable();
