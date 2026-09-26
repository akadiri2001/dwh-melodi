# DWH Mélodi — Dynamique démographique des territoires français

Chaîne décisionnelle complète et locale : API Mélodi (INSEE) → ETL → entrepôt PostgreSQL en architecture médaillon → Power BI, avec supervision Elasticsearch / Kibana.

Aucun service cloud, aucun composant payant.

## Démarrage

```bash
cd docker
cp .env.example .env
# Renseigner les mots de passe dans .env
# Clé de chiffrement Kibana : openssl rand -hex 16
docker compose up -d
```

Sous Linux, avant le premier lancement :

```bash
sudo sysctl -w vm.max_map_count=262144
```

## Vérifications

| Quoi | Commande / URL | Attendu |
|---|---|---|
| Conteneurs | `docker compose ps` | postgres, elasticsearch, kibana en `healthy` |
| PostgreSQL | `docker exec -it dwh-postgres psql -U postgres -d dwh -c '\dn'` | schémas `bronze`, `silver`, `gold` |
| Elasticsearch | `curl -u elastic:<mdp> http://localhost:9200` | réponse JSON, version 8.x |
| Licence (doit rester gratuite) | `curl -u elastic:<mdp> http://localhost:9200/_license` | `"type" : "basic"` |
| Kibana | http://localhost:5601 | login `elastic` + mot de passe du `.env` |

## Supervision (optionnelle au démarrage)

```bash
docker compose --profile supervision up -d
```

Filebeat lit les fichiers `logs/*.ndjson` produits par le joblet `jl_log_execution` et les indexe dans Elasticsearch.

## Architecture

- `bronze` — payload JSON brut de l'API, immuable, insert seul
- `silver` — une ligne par observation, typée, contrôlée
- `gold` — modèle en étoile (`dim_geo` en SCD2, `f_population`), seule couche exposée à Power BI

Le compte `bi_reader` n'a un accès en lecture que sur `gold`.

## Arrêt

```bash
docker compose down        # conserve les données
docker compose down -v     # supprime les volumes — tout est à recharger
```
