-- =====================================================================
-- GOLD : dimensions du modele en etoile.
-- dim_geo en SCD1 assume (un seul millesime de COG dans la source),
-- avec cog_millesime en cle naturelle pour une bascule SCD2 ulterieure.
-- =====================================================================

SET search_path TO gold;

DROP TABLE IF EXISTS gold.f_population;
DROP TABLE IF EXISTS gold.dim_geo;
DROP TABLE IF EXISTS gold.dim_temps;
DROP TABLE IF EXISTS gold.dim_mesure;
DROP TABLE IF EXISTS gold.dim_source;

-- ---------------------------------------------------------------------
-- dim_geo : hierarchie auto-referencee, tous niveaux dans une table
-- ---------------------------------------------------------------------
CREATE TABLE gold.dim_geo (
    sk_geo         BIGSERIAL    PRIMARY KEY,
    cog_millesime  SMALLINT     NOT NULL,
    code_geo       VARCHAR(20)  NOT NULL,
    libelle        VARCHAR(200),                  -- absent de l API, enrichi en v2
    niveau_geo     VARCHAR(10)  NOT NULL,
    code_parent    VARCHAR(20),
    sk_parent      BIGINT       REFERENCES gold.dim_geo(sk_geo),
    id_execution   VARCHAR(36),
    date_maj       TIMESTAMP    NOT NULL DEFAULT now(),

    CONSTRAINT uq_dim_geo UNIQUE (cog_millesime, code_geo),   -- controle M9
    CONSTRAINT ck_dim_geo_niveau
        CHECK (niveau_geo IN ('COM','ARM','ARR','DEP','REG','FRANCE'))
);

COMMENT ON TABLE  gold.dim_geo IS 'SCD1. La source ne diffuse qu un millesime de COG (2025).';
COMMENT ON COLUMN gold.dim_geo.sk_parent IS 'Hierarchie : COM -> DEP -> REG -> FRANCE';

CREATE INDEX idx_dim_geo_niveau ON gold.dim_geo (niveau_geo);
CREATE INDEX idx_dim_geo_parent ON gold.dim_geo (sk_parent);

-- ---------------------------------------------------------------------
-- dim_temps : grain = millesime
-- ---------------------------------------------------------------------
CREATE TABLE gold.dim_temps (
    sk_temps        SMALLSERIAL PRIMARY KEY,
    millesime       SMALLINT    NOT NULL UNIQUE,
    decennie        SMALLINT    NOT NULL,
    est_recensement BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT ck_dim_temps CHECK (millesime BETWEEN 1960 AND 2100)
);

-- ---------------------------------------------------------------------
-- dim_mesure : PMUN et PSDC, jamais additionnables entre elles
-- ---------------------------------------------------------------------
CREATE TABLE gold.dim_mesure (
    sk_mesure       SMALLSERIAL PRIMARY KEY,
    code_mesure     VARCHAR(10) NOT NULL UNIQUE,
    libelle_mesure  VARCHAR(100) NOT NULL,
    periode_usage   VARCHAR(100),
    ordre_affichage SMALLINT
);

INSERT INTO gold.dim_mesure (code_mesure, libelle_mesure, periode_usage, ordre_affichage) VALUES
  ('PMUN', 'Population municipale',            'Recensements recents (depuis 2006)', 1),
  ('PSDC', 'Population sans doubles comptes',  'Concept anterieur a 1999',           2);

COMMENT ON TABLE gold.dim_mesure IS 'Deux concepts successifs. Ne JAMAIS sommer PMUN et PSDC.';

-- ---------------------------------------------------------------------
-- dim_source : tracabilite de l extraction
-- ---------------------------------------------------------------------
CREATE TABLE gold.dim_source (
    sk_source        SMALLSERIAL PRIMARY KEY,
    dataset_id       VARCHAR(100) NOT NULL,
    niveau_interroge VARCHAR(10)  NOT NULL,
    date_extraction  DATE         NOT NULL,
    CONSTRAINT uq_dim_source UNIQUE (dataset_id, niveau_interroge, date_extraction)
);
