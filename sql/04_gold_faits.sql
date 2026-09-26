-- =====================================================================
-- GOLD : table de faits + vues d agregat pour Power BI.
-- Rechargement : delete-insert par (niveau_geo, millesime), en transaction.
-- =====================================================================

SET search_path TO gold;

CREATE TABLE gold.f_population (
    sk_population     BIGSERIAL     PRIMARY KEY,
    sk_geo            BIGINT        NOT NULL REFERENCES gold.dim_geo(sk_geo),
    sk_temps          SMALLINT      NOT NULL REFERENCES gold.dim_temps(sk_temps),
    sk_mesure         SMALLINT      NOT NULL REFERENCES gold.dim_mesure(sk_mesure),
    sk_source         SMALLINT      REFERENCES gold.dim_source(sk_source),
    valeur_population NUMERIC(14,2) NOT NULL,

    -- Colonnes de partition, denormalisees pour le delete-insert
    niveau_geo        VARCHAR(10)   NOT NULL,
    millesime         SMALLINT      NOT NULL,

    id_execution      VARCHAR(36)   NOT NULL,
    date_chargement   TIMESTAMP     NOT NULL DEFAULT now(),

    CONSTRAINT uq_f_population UNIQUE (sk_geo, sk_temps, sk_mesure),
    CONSTRAINT ck_f_valeur CHECK (valeur_population >= 0)
);

COMMENT ON TABLE  gold.f_population IS 'Grain : une valeur par territoire, millesime et mesure.';
COMMENT ON COLUMN gold.f_population.niveau_geo IS 'Denormalise pour le DELETE par partition';
COMMENT ON COLUMN gold.f_population.id_execution IS 'Correlation avec les logs Kibana';

CREATE INDEX idx_f_partition  ON gold.f_population (niveau_geo, millesime);
CREATE INDEX idx_f_geo        ON gold.f_population (sk_geo);
CREATE INDEX idx_f_temps      ON gold.f_population (sk_temps);
CREATE INDEX idx_f_execution  ON gold.f_population (id_execution);

-- ---------------------------------------------------------------------
-- Resultats des controles qualite : API et metier
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dq_results;

CREATE TABLE gold.dq_results (
    id_resultat          BIGSERIAL   PRIMARY KEY,
    id_execution         VARCHAR(36) NOT NULL,
    famille              VARCHAR(10) NOT NULL,      -- api / metier
    code_controle        VARCHAR(10) NOT NULL,      -- A1..A7, M1..M9
    libelle              VARCHAR(200) NOT NULL,
    severite             VARCHAR(20) NOT NULL,      -- bloquant / avertissement / journalisation
    table_cible          VARCHAR(100),
    nb_lignes_controlees BIGINT,
    nb_lignes_ko         BIGINT,
    taux_conformite      NUMERIC(5,4),
    statut               VARCHAR(10) NOT NULL,      -- OK / KO
    detail               TEXT,
    horodatage           TIMESTAMP   NOT NULL DEFAULT now(),

    CONSTRAINT ck_dq_famille  CHECK (famille  IN ('api','metier')),
    CONSTRAINT ck_dq_severite CHECK (severite IN ('bloquant','avertissement','journalisation')),
    CONSTRAINT ck_dq_statut   CHECK (statut   IN ('OK','KO'))
);

CREATE INDEX idx_dq_execution ON gold.dq_results (id_execution, famille);

-- ---------------------------------------------------------------------
-- Vues pour Power BI
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW gold.v_population AS
SELECT g.code_geo,
       g.libelle,
       g.niveau_geo,
       gp.code_geo   AS code_parent,
       t.millesime,
       m.code_mesure,
       m.libelle_mesure,
       f.valeur_population
FROM gold.f_population f
JOIN gold.dim_geo    g  ON g.sk_geo    = f.sk_geo
LEFT JOIN gold.dim_geo gp ON gp.sk_geo = g.sk_parent
JOIN gold.dim_temps  t  ON t.sk_temps  = f.sk_temps
JOIN gold.dim_mesure m  ON m.sk_mesure = f.sk_mesure;

-- Controle M2/M3 : la somme des enfants doit egaler la valeur du parent
CREATE OR REPLACE VIEW gold.v_coherence_hierarchique AS
SELECT p.code_geo        AS code_parent,
       p.niveau_geo      AS niveau_parent,
       t.millesime,
       m.code_mesure,
       fp.valeur_population           AS valeur_parent,
       SUM(fe.valeur_population)      AS somme_enfants,
       fp.valeur_population - SUM(fe.valeur_population) AS ecart
FROM gold.f_population fp
JOIN gold.dim_geo    p  ON p.sk_geo    = fp.sk_geo
JOIN gold.dim_temps  t  ON t.sk_temps  = fp.sk_temps
JOIN gold.dim_mesure m  ON m.sk_mesure = fp.sk_mesure
JOIN gold.dim_geo    e  ON e.sk_parent = p.sk_geo
JOIN gold.f_population fe ON fe.sk_geo = e.sk_geo
                        AND fe.sk_temps  = fp.sk_temps
                        AND fe.sk_mesure = fp.sk_mesure
GROUP BY p.code_geo, p.niveau_geo, t.millesime, m.code_mesure, fp.valeur_population;

COMMENT ON VIEW gold.v_coherence_hierarchique IS 'Support des controles M2 et M3 : ecart attendu = 0';

-- ---------------------------------------------------------------------
-- Droits de lecture pour Power BI
-- ---------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO bi_reader;
