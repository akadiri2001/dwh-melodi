-- =====================================================================
-- SILVER : une ligne par observation, typee, GEO decompose.
-- Rechargement : delete-insert par (niveau_geo, millesime).
-- =====================================================================

SET search_path TO silver;

DROP TABLE IF EXISTS silver.sl_populations;
DROP TABLE IF EXISTS silver.sl_rejets;

CREATE TABLE silver.sl_populations (
    id_observation     BIGSERIAL    PRIMARY KEY,
    cog_millesime      SMALLINT     NOT NULL,      -- segment 1 de GEO : 2025
    niveau_geo         VARCHAR(10)  NOT NULL,      -- segment 2 : COM/ARM/ARR/DEP/REG/FRANCE
    code_geo           VARCHAR(20)  NOT NULL,      -- segment 3 : 15113, 11, FRANCE...
    millesime          SMALLINT     NOT NULL,      -- TIME_PERIOD
    code_mesure        VARCHAR(10)  NOT NULL,      -- PMUN / PSDC
    valeur_population  NUMERIC(14,2) NOT NULL,     -- notation scientifique parsee
    freq               CHAR(1),                    -- A, constant
    id_payload         BIGINT       NOT NULL,      -- tracabilite vers le Bronze
    id_execution       VARCHAR(36)  NOT NULL,
    date_traitement    TIMESTAMP    NOT NULL DEFAULT now(),

    CONSTRAINT uq_sl_observation
        UNIQUE (cog_millesime, niveau_geo, code_geo, millesime, code_mesure),
    CONSTRAINT ck_sl_niveau
        CHECK (niveau_geo IN ('COM','ARM','ARR','DEP','REG','FRANCE')),
    CONSTRAINT ck_sl_mesure
        CHECK (code_mesure IN ('PMUN','PSDC')),
    CONSTRAINT ck_sl_valeur
        CHECK (valeur_population >= 0),
    CONSTRAINT ck_sl_millesime
        CHECK (millesime BETWEEN 1960 AND 2100)
);

COMMENT ON TABLE silver.sl_populations IS 'Observations aplaties. Controles API A4, A6, A7 appliques ici.';

-- Partition logique de rechargement
CREATE INDEX idx_sl_partition ON silver.sl_populations (niveau_geo, millesime);
CREATE INDEX idx_sl_geo       ON silver.sl_populations (code_geo, millesime);
CREATE INDEX idx_sl_execution ON silver.sl_populations (id_execution);

-- ---------------------------------------------------------------------
-- Rejets : rien ne disparait silencieusement.
-- ---------------------------------------------------------------------
CREATE TABLE silver.sl_rejets (
    id_rejet         BIGSERIAL   PRIMARY KEY,
    id_execution     VARCHAR(36) NOT NULL,
    id_payload       BIGINT,
    code_controle    VARCHAR(10) NOT NULL,        -- A4, A6, A7, M1...
    motif            TEXT        NOT NULL,
    observation_brute JSONB,
    date_rejet       TIMESTAMP   NOT NULL DEFAULT now()
);

CREATE INDEX idx_rejets_execution ON silver.sl_rejets (id_execution, code_controle);
