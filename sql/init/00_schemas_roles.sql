-- Socle du DWH Melodi : schemas medaillon + roles.
-- Execute automatiquement au premier demarrage du conteneur postgres.

\set etl_user    `echo "$ETL_USER"`
\set etl_pwd     `echo "$ETL_PASSWORD"`
\set bi_user     `echo "$BI_USER"`
\set bi_pwd      `echo "$BI_PASSWORD"`

-- ---------- Roles ----------
CREATE ROLE :etl_user LOGIN PASSWORD :'etl_pwd';
CREATE ROLE :bi_user  LOGIN PASSWORD :'bi_pwd';

-- ---------- Schemas medaillon ----------
CREATE SCHEMA bronze AUTHORIZATION :etl_user;
CREATE SCHEMA silver AUTHORIZATION :etl_user;
CREATE SCHEMA gold   AUTHORIZATION :etl_user;

COMMENT ON SCHEMA bronze IS 'Donnee brute API Melodi, immuable, insert seul';
COMMENT ON SCHEMA silver IS 'Donnee aplatie, typee, controlee';
COMMENT ON SCHEMA gold   IS 'Modele en etoile expose au metier';

-- ---------- Droits ETL ----------
GRANT ALL ON SCHEMA bronze, silver, gold TO :etl_user;

-- ---------- Droits BI : lecture seule sur gold uniquement ----------
GRANT USAGE ON SCHEMA gold TO :bi_user;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO :bi_user;
ALTER DEFAULT PRIVILEGES FOR ROLE :etl_user IN SCHEMA gold
  GRANT SELECT ON TABLES TO :bi_user;

-- Le compte BI ne doit voir ni bronze ni silver.
REVOKE ALL ON SCHEMA bronze, silver FROM :bi_user;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
