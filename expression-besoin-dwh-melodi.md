# Projet DWH Mélodi — Expression du besoin

**Auteur :** Anas Kadiri
**Version :** 2.0 — mise à jour après exploration réelle de l'API
**Source unique :** API Mélodi (INSEE)

> **Ce qui change par rapport à la v1.** L'exploration de l'API a invalidé quatre hypothèses : le jeu de données retenu (un seul millésime dans `DS_POPULATIONS_REFERENCE`), les paramètres de pagination (`maxResult`/`page`, pas `limit`/`offset`), les modalités de mesure (`PMUN`/`PSDC`, pas de population totale) et la nécessité du SCD2 (géographie harmonisée en COG 2025). Toutes les sections concernées ont été reprises.

---

## 1. Contexte et objectif

Construire, en local et sans cloud, une chaîne décisionnelle complète et rejouable : ingestion d'une API publique, modélisation en étoile selon l'architecture médaillon, contrôle qualité industrialisé, restitution Power BI et supervision technique via Elasticsearch/Kibana.

**Objectif de démonstration :** montrer la maîtrise d'un cycle data end-to-end (API → ETL → DWH → BI + observabilité), pas produire une étude statistique inédite.

**Étude retenue :** *Dynamique démographique des territoires français, 1968-2023* — populations municipales issues du recensement, déclinées par niveau géographique sur plus d'un demi-siècle.

---

## 2. Source de données

### 2.1 Caractéristiques de l'API

| Élément | Valeur constatée |
|---|---|
| API | Mélodi (INSEE) |
| Authentification | Aucune |
| Quota | 30 requêtes/minute — au-delà : HTTP 429 |
| Format | JSON (en-tête `Accept: application/json` obligatoire, sinon RDF/XML) |
| Catalogue | `/melodi/catalog/all` — 147 jeux de données |
| Données | `/melodi/data/{DS_NAME}` |
| Fichier complet | `/melodi/file/{DS}/{DS}_CSV_FR` — archive ZIP, ~5 Mo |

### 2.2 Jeu de données retenu

**`DS_POPULATIONS_HISTORIQUES`** — « Populations municipales de 1968 à 2023 ».

| Propriété | Valeur |
|---|---|
| Observations | 813 234 |
| Période | 1968 → 2023 |
| Structure | `DSD_POPULATIONS_REFERENCE` |
| Niveaux géographiques | `COM`, `ARM`, `ARR`, `DEP`, `REG`, `FRANCE` |
| Périmètre spatial | France hors Mayotte |
| Périodicité | Annuelle |

**Pourquoi pas `DS_POPULATIONS_REFERENCE`** — envisagé en v1, il ne contient qu'un seul millésime (2023, 106 065 observations). Sans profondeur temporelle, aucune analyse d'évolution n'est possible. Les deux jeux partageant la même structure, un basculement ou un cumul reste simple.

### 2.3 Structure d'une observation

```json
{
  "dimensions": {
    "GEO": "2025-COM-15113",
    "FREQ": "A",
    "TIME_PERIOD": "2010",
    "POPREF_MEASURE": "PMUN"
  },
  "measures": {
    "OBS_VALUE_NIVEAU": { "value": 197.0 }
  }
}
```

**Le champ `GEO` est composite** : `<millésime COG>-<niveau>-<code territoire>`. À décomposer en trois colonnes dès le Silver — c'est lui qui fournit le `niveau_geo` de la dimension géographique.

**`FREQ` vaut `A` partout** : attribut constant, pas une dimension. À conserver en Bronze pour la fidélité, à ignorer en Gold.

**Deux mesures seulement** :

| Code | Signification | Période d'usage |
|---|---|---|
| `PMUN` | Population municipale | Recensements récents |
| `PSDC` | Population sans doubles comptes | Concept antérieur à 1999 |

`PTOT` n'existe pas dans ce jeu — vérifié, la requête renvoie zéro observation. Les deux concepts se succèdent dans le temps plutôt que de coexister, ce qui interdit toute somme entre eux.

**Piège de parsing** : les valeurs reviennent en notation scientifique (`1.2380964E7` pour 12 380 964). Extraction en `Double` ou `BigDecimal`, jamais en entier.

### 2.4 Pagination

```
/melodi/data/DS_POPULATIONS_HISTORIQUES?maxResult=1000&page=1
```

Le bloc `paging` de la réponse expose :

| Champ | Présence | Usage |
|---|---|---|
| `first` | Toujours | — |
| `next` | Dès la page 2 | URL de la page suivante |
| `previous` | Dès la page 2 | — |
| `isLast` | Dès la page 2 | **Condition de sortie de boucle** |

Aucun total d'observations n'est exposé : la boucle est donc une boucle `While` pilotée par `isLast`, avec repli sur « page vide » puisque la page 1 n'expose pas ce champ.

**Filtrage** : les dimensions se passent en paramètres avec leur valeur complète — `?GEO=2025-REG-11` fonctionne, `?GEO=11` non.

### 2.5 Décision de périmètre v1

813 234 observations à 30 requêtes/minute représentent un temps d'ingestion prohibitif si l'on descend au niveau communal. Le périmètre v1 se limite donc aux niveaux **`FRANCE`, `REG` et `DEP`**, soit de l'ordre de 13 000 observations — quelques minutes d'ingestion, et l'essentiel de la valeur analytique.

Le niveau `COM` est reporté en v2, où il justifiera pleinement la double boucle et le traitement des fusions de communes.

**À tester en début d'ingestion** : la valeur maximale acceptée pour `maxResult`. Elle conditionne directement le nombre d'appels, donc la durée.

---

## 3. Architecture cible

```
                    ┌─────────────────────┐
                    │   API Mélodi INSEE  │
                    └──────────┬──────────┘
                               │ HTTPS / JSON paginé
                    ┌──────────▼──────────┐
                    │  Job ingestion      │──── logs JSON ────┐
                    └──────────┬──────────┘                   │
                               │                              │
                    ┌──────────▼──────────┐                   │
                    │ PostgreSQL BRONZE   │                   │
                    │ (payload brut)      │                   │
                    └──────────┬──────────┘                   │
                               │                              │
                    ┌──────────▼──────────┐                   │
                    │ PostgreSQL SILVER   │                   │
                    │ (à plat, typé)      │                   │
                    └──────────┬──────────┘                   │
                               │                              │
                    ┌──────────▼──────────┐                   │
                    │  Job transformation │──── logs + DQ ────┤
                    └──────────┬──────────┘                   │
                               │                              │
          ┌────────────────────▼────────────┐        ┌────────▼─────────┐
          │  PostgreSQL GOLD (étoile)       │        │  Elasticsearch   │
          │  + dq_results                   │        └────────┬─────────┘
          └────────────────────┬────────────┘                 │
                               │                     ┌────────▼─────────┐
                    ┌──────────▼──────────┐          │     Kibana       │
                    │     Power BI        │          │  (supervision)   │
                    └─────────────────────┘          └──────────────────┘
```

### 3.1 Répartition Docker / hôte

| Composant | Où | Pourquoi |
|---|---|---|
| PostgreSQL (bronze, silver, gold) | Conteneur | Reproductibilité, versions figées |
| Elasticsearch 8 (licence Basic) | Conteneur | `xpack.security.enabled=true`, TLS HTTP désactivé |
| Kibana | Conteneur | Compte `kibana_system` |
| Filebeat | Conteneur (profil `supervision`) | Expédie les logs NDJSON vers ES |
| Job ETL exporté | Conteneur `eclipse-temurin:17-jre` | Exécutable Java autonome |
| Studio ETL (IDE) | Hôte | IDE Eclipse lourd, non conteneurisable utilement |
| Power BI Desktop | Hôte | Windows uniquement, se connecte à `localhost:5432` |

### 3.2 Détail des services

| Service | Image | Port hôte | Volume |
|---|---|---|---|
| `postgres` | `postgres:16-alpine` | 5432 | `pgdata` + `./sql/init` en lecture seule |
| `elasticsearch` | `elasticsearch:8.15.0` | 9200 | `esdata` |
| `kibana` | `kibana:8.15.0` | 5601 | — |
| `es-setup` | `elasticsearch:8.15.0` | — | éphémère, positionne le mot de passe `kibana_system` |
| `filebeat` | `beats/filebeat:8.15.0` | — | `./logs` en lecture seule |
| `etl-runner` | build local | — | `./talend/jobs`, `./logs` |

**Réseau** : un bridge unique `dwh-net`. Adressage par nom de service (`postgres:5432`), jamais `localhost` entre conteneurs.

**Secrets** : `.env` non commité, `.env.example` versionné.

**Healthchecks** : `depends_on` avec `condition: service_healthy`, sinon Kibana et l'ETL démarrent trop tôt.

**Contrainte mémoire constatée** : 7,6 Go disponibles pour Docker. Heap Elasticsearch à 1 Go ; à ramener à 512 Mo si des conteneurs sont tués en cours d'exécution.

### 3.3 Contrainte budgétaire : zéro euro

| Composant | Statut | Vigilance |
|---|---|---|
| API Mélodi | Gratuite, sans authentification | — |
| PostgreSQL | Open source | — |
| Elasticsearch 8 | Licence **Basic** gratuite | Vérifier `GET /_license` → `basic` ; ne jamais activer d'essai |
| Kibana | Basic gratuite | Alerting et Machine Learning sont payants — ne pas les utiliser |
| Docker Desktop | Gratuit en usage personnel | — |
| GitHub | Gratuit, dépôts privés inclus | — |
| **Power BI Desktop** | **Gratuit** | Windows uniquement |
| Power BI Service | **Payant (Pro)** | ⚠️ Rester en Desktop, versionner le `.pbix`, documenter par captures |

> ⚠️ **Talend Open Studio a été arrêté par Qlik le 31 janvier 2024** : plus de téléchargement officiel ni de correctifs. Le projet reste à coût nul avec une installation existante, à documenter comme version archivée. Alternatives libres et actives : **Apache Hop** (successeur de Pentaho Kettle) ou **Pentaho Data Integration CE**. Le modèle, les contrôles et la supervision décrits ici sont indépendants de l'outil : un changement n'affecte que la section 5.

---

## 4. Modèle de données

### 4.1 Grain de la table de faits

> **Une ligne = une valeur de population pour un territoire, un millésime et un type de mesure.**

Additif sur la géographie à niveau constant, non additif dans le temps, et **jamais additif entre `PMUN` et `PSDC`** — les deux concepts ne s'additionnent pas, ils se succèdent.

### 4.2 Schéma en étoile

```
              ┌────────────────┐
              │   dim_temps    │
              │────────────────│
              │ sk_temps  (PK) │
              │ millesime      │
              │ est_recensement│
              └───────┬────────┘
                      │
┌──────────────┐   ┌──▼─────────────────────┐   ┌──────────────────┐
│   dim_geo    │   │     f_population       │   │   dim_mesure     │
│──────────────│   │────────────────────────│   │──────────────────│
│ sk_geo  (PK) ├──►│ sk_population    (PK)  │◄──┤ sk_mesure   (PK) │
│ code_geo     │   │ sk_geo           (FK)  │   │ code_mesure      │
│ libelle      │   │ sk_temps         (FK)  │   │ libelle_mesure   │
│ niveau_geo   │   │ sk_mesure        (FK)  │   │ periode_usage    │
│ cog_millesime│   │ sk_source        (FK)  │   └──────────────────┘
│ code_parent  │   │ valeur_population      │
│ sk_parent    │   │ id_execution           │   ┌──────────────────┐
└──────────────┘   │ date_chargement        │◄──┤   dim_source     │
                   └────────────────────────┘   │──────────────────│
                                                │ sk_source   (PK) │
                                                │ dataset_id       │
                                                │ niveau_interroge │
                                                │ date_extraction  │
                                                └──────────────────┘
```

### 4.3 Détail des tables

**`dim_geo`** — une seule table pour tous les niveaux, avec `niveau_geo` issu du deuxième segment de `GEO` et `sk_parent` pointant vers la ligne parente. `cog_millesime` porte le premier segment (`2025`). Les libellés ne figurant pas dans la réponse de l'API, ils seront à enrichir depuis le COG ou laissés vides en v1.

**`dim_temps`** — grain : le millésime. `est_recensement` distingue les années de recensement des années intercalaires.

**`dim_mesure`** — deux lignes : `PMUN` et `PSDC`. `periode_usage` documente la bascule conceptuelle, qui explique les ruptures de série dans les rapports.

**`dim_source`** — traçabilité : dataset interrogé, niveau demandé, date d'extraction.

**`f_population`** — porte `id_execution`, clé de corrélation avec les logs Kibana.

### 4.4 Architecture médaillon

Trois schémas PostgreSQL distincts dans la même instance.

```
        API Mélodi (JSON paginé)
                 │
                 ▼
╔════════════════════════════════════════════════════════════════╗
║  🥉 BRONZE — schéma `bronze`                                   ║
║  br_melodi_payload                                             ║
║    id_payload, id_execution, dataset_id, niveau_interroge,     ║
║    numero_page, url_appelee, payload_json (JSONB),             ║
║    nb_observations_page, est_derniere_page, date_ingestion     ║
║                                                                ║
║  Règles : brut tel que reçu · aucune transformation ·          ║
║  IMMUABLE (INSERT seul)                                        ║
║  Objectif : rejouer tout l'aval sans rappeler l'API            ║
╚════════════════════════════════════════════════════════════════╝
                 │  aplatissement + décomposition de GEO + typage
                 ▼
╔════════════════════════════════════════════════════════════════╗
║  🥈 SILVER — schéma `silver`                                   ║
║  sl_populations                                                ║
║    cog_millesime, niveau_geo, code_geo,   ← GEO décomposé      ║
║    millesime, code_mesure, valeur_population (NUMERIC),        ║
║    freq, id_execution, date_traitement                         ║
║  sl_rejets (ligne écartée + motif + payload d'origine)         ║
║                                                                ║
║  Règles : une ligne par observation · types natifs ·           ║
║  dédoublonnage · contrôles API appliqués ICI                   ║
╚════════════════════════════════════════════════════════════════╝
                 │  modélisation dimensionnelle
                 ▼
╔════════════════════════════════════════════════════════════════╗
║  🥇 GOLD — schéma `gold`                                       ║
║  dim_geo · dim_temps · dim_mesure · dim_source                 ║
║  f_population · vues d'agrégat · dq_results                    ║
║                                                                ║
║  Règles : étoile · clés de substitution · contrôles métier ·   ║
║  SEULE couche exposée à Power BI                               ║
╚════════════════════════════════════════════════════════════════╝
                 │
                 ▼
            Power BI (lecture seule sur `gold`)
```

**Bonnes pratiques appliquées**

| Principe | Mise en œuvre |
|---|---|
| Séparation stricte des couches | Trois schémas, aucun saut : le Gold ne lit jamais le Bronze |
| Immuabilité du Bronze | `INSERT` seul, `payload_json` en JSONB conservé tel quel |
| Rejouabilité | Une anomalie en Gold se corrige depuis le Bronze **sans rappeler l'API** — décisif avec un quota de 30 req/min |
| Qualité croissante | Contrôles API en entrée du Silver, contrôles métier en entrée du Gold |
| Traçabilité bout en bout | `id_execution` propagé Bronze → Silver → Gold → Kibana |
| Idempotence | Chaque couche reconstructible depuis la précédente |
| Exposition maîtrisée | `bi_reader` n'a de droits qu'en lecture sur `gold` |
| Gestion des rejets | `sl_rejets` conserve les lignes écartées avec leur motif |

### 4.5 Historisation de `dim_geo` : SCD1 assumé

**Décision : SCD type 1, avec la colonne `cog_millesime` conservée.**

**Justification.** L'exploration a montré que toutes les observations portent le préfixe `2025-`, y compris celles de 1982. L'INSEE rediffuse l'intégralité de l'historique dans la géographie communale en vigueur en 2025 — il n'existe donc qu'un seul millésime de COG dans ce jeu, et un SCD2 n'aurait aucune version à historiser. Le mettre en place reviendrait à ajouter de la complexité pour une capacité jamais exercée.

**Ce que ça implique pour l'analyse** — à documenter dans le rapport : les populations de 1968 sont exprimées dans le découpage communal de 2025, ce qui rend les comparaisons temporelles **plus justes** (pas d'artefact de fusion) mais ne reflète pas la réalité administrative de l'époque.

**Ce qui reste prêt** : `cog_millesime` est en clé naturelle avec `code_geo`. Le jour où un second millésime de COG apparaît — en croisant un autre jeu, ou lors d'une rediffusion — la bascule en SCD2 consiste à ajouter `date_debut`, `date_fin` et `est_courant` sans refondre le modèle.

**Contrôle associé** : unicité de `(cog_millesime, code_geo)` dans `dim_geo`.

### 4.6 Stratégie de rechargement

| Objet | Régime | Clé de partition ou rapprochement |
|---|---|---|
| `bronze.br_melodi_payload` | **Append-only** | Aucune suppression, jamais |
| `silver.sl_populations` | **Delete-insert par partition** | `(niveau_geo, millesime)` |
| `silver.sl_rejets` | Append-only | — |
| `gold.dim_geo` | Upsert | `(cog_millesime, code_geo)` |
| `gold.dim_temps`, `dim_mesure`, `dim_source` | Upsert | Clé naturelle |
| `gold.f_population` | **Delete-insert par partition** | `(niveau_geo, millesime)` |
| `gold.dq_results` | Append-only | — |

**Pourquoi le delete-insert pour les faits.** Les données arrivent par lot complet, jamais en delta. Supprimer la partition puis réinsérer garantit que l'état final reflète la source, disparitions comprises, et rend le job idempotent. Un upsert ne supprimerait jamais rien : une pagination tronquée laisserait d'anciennes lignes sans aucun signal.

**Sécurisation.** DELETE et INSERT dans une même transaction : connexion avec auto-commit désactivé, commit en fin de job, rollback sur la branche d'erreur. Sans cela, un échec après le DELETE laisse la partition vide.

**Reprise sur incident.** Relancer le job sur la même partition. Aucun nettoyage manuel.

---

## 5. Développement ETL

### 5.1 Découpage des jobs

| Job | Rôle |
|---|---|
| `job_ingestion_melodi` | Appels API paginés → `bronze.br_melodi_payload` |
| `job_transformation_silver` | Bronze → Silver (aplatissement, décomposition de `GEO`, typage) |
| `job_transformation_gold` | Silver → dimensions → faits |
| `job_qualite` | Exécution des contrôles → `dq_results` |
| `job_orchestrateur` | Enchaînement via `tRunJob`, propagation de `id_execution` |
| `jl_log_execution` | **Joblet** de journalisation, appelé par tous les jobs |

`id_execution` (UUID) est généré une seule fois par l'orchestrateur dans un `tPreJob` et transmis en contexte — c'est ce qui rend possible la corrélation DWH ↔ Kibana.

### 5.2 Paramétrage externalisé — `params.properties`

Aucune donnée de connexion dans les jobs : chargement au démarrage par `tFileInputProperties → tContextLoad`.

```properties
# --- API Mélodi ---
melodi.api_base_url=https://api.insee.fr/melodi
melodi.dataset_id=DS_POPULATIONS_HISTORIQUES
melodi.niveaux=FRANCE,REG,DEP
melodi.cog_millesime=2025
melodi.max_result=1000
melodi.sleep_ms=2000
melodi.max_pages=2000
melodi.nb_retry_max=3

# --- PostgreSQL ---
postgres.host=localhost
postgres.port=5432
postgres.database=dwh
postgres.user=etl_user
postgres.password=********

# --- Elasticsearch ---
elastic.host=localhost
elastic.port=9200
elastic.user=elastic
elastic.password=********
elastic.index_prefix=logs

# --- Divers ---
env.nom=local
log.repertoire=./logs
```

**Points d'attention**
- Le chemin du fichier est lui-même un paramètre (`params_file`), passé au `run.sh` : le **même livrable** tourne sur l'hôte (`localhost`) et dans Docker (`postgres`, `elasticsearch`) sans recompilation.
- `tContextLoad` en mode « Error » si une clé manque : mieux vaut un échec immédiat qu'une connexion à une base par défaut.
- Versionner `params.example.properties` uniquement ; `params*.properties` dans le `.gitignore`.
- Ne jamais journaliser le contexte après chargement — les mots de passe partiraient dans Elasticsearch.

### 5.3 Pagination — `tLoop` While piloté par `isLast`

```
tPreJob
 └─ tJava : context.page = 1
            context.has_more = true

tLoop  [type: While]
  Condition : context.has_more && context.page <= context.max_pages
  │
  ├─ tRESTClient
  │    URL : {api_base_url}/data/{dataset_id}
  │          ?GEO={cog_millesime}-{niveau}-{code}
  │          &maxResult={max_result}&page={page}
  │    Accept : application/json
  │
  ├─ tPostgresqlOutput → bronze.br_melodi_payload  (payload brut)
  │
  ├─ tExtractJSONFields
  │    Loop XPath : /observations
  │    Champs : dimensions.GEO, dimensions.FREQ,
  │             dimensions.TIME_PERIOD, dimensions.POPREF_MEASURE,
  │             measures.OBS_VALUE_NIVEAU.value
  │
  ├─ tJava : lecture de paging.isLast et paging.next
  │    if (isLast || nb_observations_page == 0) {
  │        context.has_more = false;
  │    } else {
  │        context.page++;
  │    }
  │
  ├─ jl_log_execution  (numero_page, code_http, latence_ms)
  │
  └─ tSleep (context.sleep_ms)
```

**Condition de sortie** : `isLast = true`. Repli sur page vide, car la page 1 n'expose pas ce champ. Garde-fou `max_pages` contre la boucle infinie.

**Boucle externe** : `tFileInputDelimited` sur la liste des niveaux et codes à interroger → `tFlowToIterate` autour de la boucle de pagination.

### 5.4 Quota et erreurs

- **30 req/min** : `tSleep` de 2 s, soit ~30 appels/minute avec le temps de traitement.
- **HTTP 429** : branche ERROR du `tRESTClient` → `tSleep` 60 s → rejeu de la même page, compteur `nb_retry`, abandon au-delà de `nb_retry_max`.
- **Erreurs 5xx** : même logique, backoff plus court.
- **Timeouts** connect et read positionnés explicitement.
- Toute erreur incrémente un compteur journalisé, jamais avalée silencieusement.

### 5.5 Alimentation de Kibana par le joblet `jl_log_execution`

Un joblet unique appelé par tous les jobs. Sans lui, la logique de log serait dupliquée et les noms de champs divergeraient — rendant les agrégations Kibana impossibles.

**Contrat d'entrée**

| Champ | Type | Origine |
|---|---|---|
| `id_execution` | String | Contexte, propagé par l'orchestrateur |
| `nom_job`, `version_job`, `etape` | String | Appelant |
| `statut` | String | `succes` / `echec` / `avertissement` |
| `horodatage_debut`, `_fin` | Date | Appelant |
| `duree_ms` | Long | Calculé |
| `nb_lignes_lues`, `_inserees`, `_rejetees` | Long | Compteurs du flux |
| `message_erreur` | String | Nullable |
| `donnees_extra` | String | JSON libre (`numero_page`, `code_http`, `latence_ms`) |

**Contenu**

```
tJobletInput
  └─ tMap   environnement ← context.env_nom
            horodatage    ← date courante
            taux_rejet    ← nb_rejetees / nb_lues
            index_cible   ← prefix + "-etl-jobs"
       └─ tFileOutputJSON  (NDJSON, append, un fichier par jour)
```

**Règle** : le joblet ne doit **jamais** faire échouer le job appelant. Sa branche d'erreur est absorbée. Une supervision indisponible ne casse pas un ETL qui fonctionne — c'est pourquoi Filebeat est préféré au POST direct vers Elasticsearch.

**Conséquence sur l'ordre de développement** : construire le joblet **avant** les jobs métier.

### 5.6 Whitelist : non nécessaire

L'API Mélodi est en open data, sans jeton ni inscription d'IP — à ne pas confondre avec Sirene ou BDM. Aucune configuration côté INSEE.

| Cas | Nécessaire ? | Action |
|---|---|---|
| Réseau d'entreprise avec proxy | Oui, si développement depuis un poste pro | `http_proxy` / `https_proxy` en contexte ou options JVM |
| Appels internes Docker derrière un proxy | Oui | ⚠️ `no_proxy` doit contenir `postgres,elasticsearch,kibana,localhost,127.0.0.1` |
| Pare-feu local | Rarement | Autoriser 5432, 9200, 5601 |
| Certificat HTTPS Mélodi | Non | Certificat public reconnu |

### 5.7 Conventions

- Nommage explicite des composants (`tREST_melodi_data`, pas `tRESTClient_1`) — les logs en dépendent.
- Rejets de `tMap` branchés vers `sl_rejets`, jamais vers `tLogRow` seul.
- Aucune valeur en dur : tout passe par le contexte.
- Export du job versionné dans `talend/jobs/`, accompagné de captures d'écran (les `.item` XML sont illisibles en revue).

---

## 6. Contrôles qualité

Deux familles, deux logiques distinctes. **Un contrôle API qui échoue signifie qu'il faut relancer le job. Un contrôle métier qui échoue signifie qu'il faut regarder la donnée** — et parfois accepter le résultat.

### 6.1 Contrôles de logique API

Ils vérifient la fidélité de l'extraction : « ai-je bien tout récupéré, sans perte ni doublon ? »

| # | Contrôle | Couche | Sévérité | Détecte |
|---|---|---|---|---|
| A1 | Code HTTP 200 sur chaque appel | Ingestion | Bloquant | Erreur réseau, 429 non géré |
| A2 | `isLast = true` atteint avant `max_pages` | Ingestion | Bloquant | Boucle interrompue, données tronquées |
| A3 | Numérotation des pages sans trou | Ingestion | Avertissement | Page perdue lors d'un retry |
| A4 | Aucun doublon `(GEO, TIME_PERIOD, POPREF_MEASURE)` | Bronze → Silver | Bloquant | Recouvrement entre appels — l'API ne trie pas ses résultats |
| A5 | Réconciliation des volumes : observations reçues = lignes Bronze = lignes Silver + rejets | Toutes | Bloquant | Perte silencieuse en transformation |
| A6 | Format de `GEO` : trois segments, niveau parmi les six connus, code non vide | Silver | Bloquant | Structure inattendue, évolution de l'API |
| A7 | `OBS_VALUE_NIVEAU` parsé en numérique, non nul après conversion | Silver | Bloquant | Notation scientifique mal interprétée |

### 6.2 Contrôles de logique métier

Ils supposent l'extraction correcte et interrogent le sens : « ces chiffres sont-ils démographiquement crédibles ? »

| # | Contrôle | Couche | Sévérité | Détecte |
|---|---|---|---|---|
| M1 | Population strictement positive | Silver | Bloquant | Valeur aberrante à la source |
| M2 | Somme des départements d'une région = valeur de la région, même millésime et même mesure | Gold | Avertissement fort | Ingestion partielle, incohérence source |
| M3 | Somme des régions = valeur `FRANCE` | Gold | Avertissement fort | Même logique, échelon supérieur |
| M4 | Total France ≈ 68 millions en 2022 | Gold | Avertissement fort | **Erreur d'unité ou de parsing à l'échelle globale** |
| M5 | Un territoire n'a pas `PMUN` et `PSDC` la même année | Silver | Avertissement | Confusion entre les deux concepts |
| M6 | Continuité : chaque territoire a une valeur à chaque millésime attendu | Gold | Avertissement | Trou dans l'historique |
| M7 | Variation entre millésimes consécutifs sous ±30 % | Gold | Journalisation | Anomalie à investiguer |
| M8 | Chaque `code_geo` rattaché à un parent existant | Gold | Bloquant | Référentiel incomplet |
| M9 | Unicité de `(cog_millesime, code_geo)` dans `dim_geo` | Gold | Bloquant | Doublon de dimension |

M4 mérite une attention particulière : c'est lui qui rattrape le piège de la notation scientifique. Si `1.2380964E7` est mal parsé, la somme France devient absurde et le contrôle le signale immédiatement.

### 6.3 Table `dq_results`

`id_execution`, `famille` (`api` / `metier`), `code_controle`, `libelle`, `severite`, `table_cible`, `nb_lignes_controlees`, `nb_lignes_ko`, `taux_conformite`, `statut`, `horodatage`, `detail`.

Cette table alimente à la fois la page qualité de Power BI et l'index `logs-dq-*` d'Elasticsearch.

### 6.4 Source de réconciliation externe

Le catalogue expose un export complet en CSV (`/melodi/file/DS_POPULATIONS_HISTORIQUES/DS_POPULATIONS_HISTORIQUES_CSV_FR`, ~5 Mo). Le télécharger une fois permet de valider indépendamment les volumes et les valeurs obtenues par l'API — un excellent filet pour le contrôle A5.

---

## 7. Restitution Power BI

### 7.1 Mesures DAX

| Mesure | Définition | Usage |
|---|---|---|
| `Population` | `CALCULATE(SUM(valeur), dim_mesure[code] = "PMUN")` | Mesure de référence |
| `Population PSDC` | Idem sur `PSDC` | Séries anciennes |
| `Population millésime précédent` | Décalage sur `dim_temps` | Comparaison |
| `Évolution absolue` | Population − millésime précédent | Delta |
| `Évolution %` | Delta / millésime précédent | KPI principal |
| `Indice base 100` | Population / Population(premier millésime) × 100 | Trajectoires comparées |
| `Poids dans le parent` | Population / Population(niveau supérieur) | Concentration territoriale |
| `Rang territorial` | `RANKX` | Classements |
| `Nb territoires` | `DISTINCTCOUNT(sk_geo)` | Contexte |
| `Taux de conformité DQ` | Moyenne sur `dq_results` | Page qualité |

> **Règle absolue** : ne jamais sommer `PMUN` et `PSDC`. Chaque mesure filtre explicitement son code. Une mesure « toutes mesures confondues » produirait des doublons sur les années de recouvrement.

### 7.2 Maquette des pages

**Page 1 — Vue d'ensemble**
Cartes KPI (population totale, nb de territoires, évolution % vs millésime précédent, dernier millésime), carte choroplèthe départementale, segments millésime / niveau / mesure.

**Page 2 — Comparaison territoriale**
Matrice hiérarchique région → département, colonnes = millésimes. Top 10 et flop 10 d'évolution. Nuage de points population initiale × évolution %. Tableau détaillé exportable.

**Page 3 — Évolution temporelle 1968-2023**
Courbe multi-millésimes, small multiples par région en indice base 100, graphique en cascade des contributions régionales. **Marquer visuellement la rupture conceptuelle PSDC → PMUN** — une ligne verticale annotée suffit, et c'est un détail qui montre la compréhension de la donnée.

**Page 4 — Qualité et exécution**
Jauge de conformité globale, barres OK/KO par contrôle avec distinction API / métier, historique des exécutions, tableau des rejets avec motif.

> La page 4 est le différenciateur du projet : elle rend la qualité visible pour le métier, pas seulement dans les logs.

### 7.3 Connexion

Mode **Import** : volumétrie faible, mise à jour par lot, et accès complet aux fonctions DAX. Compte `bi_reader`, lecture seule sur `gold`.

---

## 8. Supervision Elasticsearch / Kibana

### 8.1 Métadonnées indexées

**`logs-etl-jobs-*`** — une ligne par étape :

| Champ | Type | Contenu |
|---|---|---|
| `id_execution` | keyword | UUID, corrélation avec le DWH |
| `nom_job`, `version_job`, `etape` | keyword | Identification |
| `statut` | keyword | `succes` / `echec` / `avertissement` |
| `horodatage_debut`, `_fin` | date | |
| `duree_ms` | long | Performance |
| `nb_lignes_lues`, `_inserees`, `_rejetees` | long | Volumétrie |
| `taux_rejet` | float | Calculé |
| `message_erreur` | text | Si échec |
| `environnement` | keyword | `local` |

**`logs-api-melodi-*`** — une ligne par appel HTTP :
`id_execution`, `url_appelee`, `dataset_id`, `niveau_interroge`, `numero_page`, `nb_observations_page`, `est_derniere_page`, `code_http`, `latence_ms`, `taille_reponse_octets`, `nb_retry`, `est_429`.

**`logs-dq-*`** — miroir de `dq_results`, avec le champ `famille` pour séparer API et métier.

### 8.2 Dashboards — détail des panneaux

**Prérequis** : trois data views avec `horodatage_debut` comme champ temporel. Vérifier le mapping — `duree_ms`, `nb_lignes_*` et `latence_ms` doivent être numériques, pas des chaînes. C'est le piège classique de l'indexation automatique.

**Dashboard 1 — Santé des exécutions**

| Panneau | Type | Champs |
|---|---|---|
| Statut de la dernière exécution | Metric | `statut` |
| Nombre d'exécutions | Metric | `id_execution` distinct |
| Taux de succès | Gauge | ratio `statut:succes` |
| Durée par étape | Bar horizontal | moyenne `duree_ms` par `etape` |
| Durée dans le temps | Line | max `duree_ms` par exécution |
| Volumétrie lue / insérée / rejetée | Bar empilé | somme `nb_lignes_*` |
| Journal des erreurs | Table | `message_erreur` |

**Dashboard 2 — Performance API**

| Panneau | Type | Champs |
|---|---|---|
| Nombre d'appels | Metric | `count` |
| Latence p50 / p95 | Line | percentiles `latence_ms` |
| Codes HTTP | Camembert | `code_http` |
| Compteur de 429 | Metric avec seuil | `est_429:true` |
| **Appels par minute** | Line (date histogram) | ⚠️ Panneau clé : la courbe doit rester sous 30/min |
| Pages par niveau | Bar | max `numero_page` par `niveau_interroge` |
| Retries | Metric | somme `nb_retry` |

**Dashboard 3 — Qualité**

| Panneau | Type | Champs |
|---|---|---|
| Conformité globale | Gauge | moyenne `taux_conformite` |
| Conformité par famille | Bar | `taux_conformite` par `famille` |
| Conformité par contrôle | Bar horizontal | par `code_controle` |
| Lignes KO dans le temps | Line | somme `nb_lignes_ko` |
| Répartition par sévérité | Camembert | `severite` |
| Détail des échecs | Table | `libelle`, `nb_lignes_ko`, `detail` |

**Export** : `Stack Management → Saved Objects → Export` en `.ndjson`, versionné dans `kibana/`. Sans cet export, tout est à refaire après un `docker compose down -v`.

**À éviter (payant)** : Alerting et Machine Learning ne sont pas inclus en Basic. Un panneau avec seuil visuel remplace l'alerting.

### 8.3 Visualisations à forte valeur

Au-delà des panneaux de base, ces visualisations font la différence entre un dashboard de démonstration et un outil qu'on consulte réellement. Toutes sont disponibles en licence Basic.

**Heat map — taux de rejet par étape et par jour**
Type : Lens → Heat map. Axe X : `horodatage_debut` en date histogram journalier. Axe Y : `etape`. Couleur : moyenne de `taux_rejet`.
*Ce qu'elle révèle* : d'un coup d'œil, quelle étape dégrade la qualité et depuis quand. Une bande rouge horizontale désigne une étape fautive, une bande verticale désigne un jour anormal — le diagnostic est immédiat, ce qu'aucune courbe ne permet.

**Distribution des latences API — histogramme**
Type : Lens → Bar vertical. Axe X : `latence_ms` en intervalles de 100 ms. Axe Y : nombre d'appels.
*Ce qu'elle révèle* : une moyenne masque tout. Une distribution bimodale signale que certains appels passent par un chemin lent — typiquement les grandes pages ou les retries. C'est la visualisation qui justifie un réglage de `maxResult`.

**Somme cumulée des observations ingérées**
Type : Lens → Area, avec la fonction `cumulative_sum` sur `nb_lignes_inserees`.
*Ce qu'elle révèle* : la progression vers le volume total attendu. Un palier signifie que l'ingestion s'est arrêtée sans forcément lever d'erreur — c'est le complément visuel du contrôle A2.

**Chronologie des étapes d'une exécution**
Type : Lens → Bar horizontal empilé, axe Y `etape`, valeur `duree_ms`, filtré sur un `id_execution`.
*Ce qu'elle révèle* : la répartition du temps dans une exécution donnée. C'est le panneau qu'on regarde quand un job passe de 4 à 12 minutes.

**Répartition du volume par niveau géographique**
Type : Lens → Donut sur `niveau_interroge`, valeur somme de `nb_observations_page`.
*Ce qu'elle révèle* : l'équilibre du périmètre ingéré. Si `DEP` pèse soudain autant que `COM`, quelque chose a changé dans les filtres.

**Percentiles de durée dans le temps**
Type : Lens → Line avec trois séries : p50, p95 et p99 de `duree_ms`.
*Ce qu'elle révèle* : la dérive de performance. Le p50 peut rester stable pendant que le p99 explose — signe que les cas extrêmes se dégradent avant la moyenne.

**Table des motifs de rejet**
Type : Lens → Table. Lignes : `code_controle` et `detail`. Colonnes : somme de `nb_lignes_ko`, dernière occurrence.
*Ce qu'elle révèle* : le passage du constat au diagnostic. Un taux de conformité de 97 % ne dit rien ; savoir que les 3 % sont tous sur A6 et concernent des codes `ARM` dit quoi corriger.

**Panneau Markdown de contexte**
Type : Markdown. Contenu : rappel du périmètre, signification de chaque contrôle, lien vers le dépôt.
*Pourquoi* : un dashboard qu'on retrouve trois mois plus tard sans savoir ce qu'il mesure est inutile. Deux paragraphes de contexte valent mieux qu'un panneau de plus.

**Comparaison entre exécutions**
Type : Lens → Bar, axe X `id_execution` (top 10 par date), valeurs `nb_lignes_inserees` et `nb_lignes_rejetees`.
*Ce qu'elle révèle* : la régression entre deux lancements. Si la dernière exécution a ingéré 20 % de moins que la précédente sans erreur signalée, c'est ici qu'on le voit.

> **À ne pas faire** : empiler les panneaux parce qu'ils sont jolis. Un dashboard utile répond à une question précise — « est-ce que ça a tourné correctement ? », « pourquoi est-ce lent ? », « où est le problème de qualité ? ». Trois dashboards ciblés valent mieux qu'un seul de trente panneaux.

### 8.4 Principe de séparation

Elasticsearch/Kibana = **le technique** (ça a tourné, combien de temps, ça a planté ?). Power BI = **le métier** (combien d'habitants, quelle évolution ?). La page 4 de Power BI est le seul pont, volontairement.

---

## 9. Orchestration — cron

Sans planification, le projet reste un script lancé à la main. Un cron suffit : données annuelles, aucune dépendance complexe, aucun parallélisme. Airflow serait disproportionné.

```cron
# Rechargement mensuel — le 5 à 02h00
0 2 5 * * cd /chemin/dwh-melodi && /usr/bin/flock -n /tmp/dwh.lock \
  docker compose run --rm etl-runner \
  --context_param params_file=/opt/conf/params.docker.properties \
  >> logs/cron.log 2>&1
```

**Points d'attention**
- `flock -n` empêche deux exécutions simultanées : sans verrou, deux delete-insert se marchent dessus.
- Sortie redirigée vers le répertoire de logs, où Filebeat la récupère — un échec de lancement devient visible dans Kibana.
- `docker compose run --rm` : conteneur éphémère, rien ne tourne en permanence.
- Le code retour doit être non nul en cas d'échec, sinon cron considère l'exécution réussie.
- Cadence réaliste : mensuelle. Pour la démonstration, une exécution quotidienne rend les dashboards plus parlants.

**Alternative Airflow** : `docker-compose` en LocalExecutor avec un DAG à quatre tâches. Gratuit, mais +3 h et une consommation mémoire notable — à réserver à une v3, d'autant que 7,6 Go sont déjà partagés.

---

## 10. CI/CD — GitHub Actions

À traiter **en dernier**, une fois la chaîne fonctionnelle : une CI qui valide un projet instable ne sert à rien. C'est aussi le poste où l'apprentissage est le plus rentable.

**Gratuité** : illimité sur dépôt public, 2 000 minutes/mois sur dépôt privé.

| Job | Ce qu'il fait | Intérêt |
|---|---|---|
| `lint-sql` | `sqlfluff` sur `sql/` | Cohérence de style, erreurs de syntaxe |
| `build-runner` | `docker build` de l'image ETL | L'image reste constructible |
| `test-ddl` | Service PostgreSQL, application des DDL, assertions SQL | Un clone du dépôt est déployable |

**Assertions utiles** : les trois schémas existent, chaque FK de `f_population` pointe vers une dimension, la contrainte d'unicité `(cog_millesime, code_geo)` est présente, les droits en lecture seule sur `gold` sont appliqués.

**Ordre d'apprentissage** — chaque palier fonctionne avant le suivant :
1. Workflow « hello world » : déclencheurs, runners, logs
2. `lint-sql` : une action, une commande
3. `build-runner` : build Docker en CI
4. `test-ddl` avec `services:` : le plus riche

**Ce qu'on ne fait pas** : aucun déploiement automatisé — il n'y a pas d'environnement cible. La CI valide, elle ne livre pas. Le dire dans le README évite de laisser croire à un oubli.

---

## 11. Organisation du dépôt

```
dwh-melodi/
├── docker/
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── filebeat/filebeat.yml
│   └── job-runner/Dockerfile
├── sql/
│   ├── init/00_schemas_roles.sql
│   ├── 01_bronze.sql
│   ├── 02_silver.sql
│   ├── 03_gold_dimensions.sql
│   ├── 04_gold_faits.sql
│   └── 05_qualite.sql
├── conf/
│   └── params.example.properties
├── talend/
│   ├── jobs/          (exports .zip)
│   └── captures/      (copies d'écran)
├── kibana/
│   └── export_dashboards.ndjson
├── powerbi/
│   └── rapport_demographie.pbix
├── logs/
├── docs/
│   ├── expression-besoin.md
│   └── modele-etoile.png
├── .github/workflows/
└── README.md
```

---

## 12. Risques identifiés

| Risque | Impact | Parade |
|---|---|---|
| Volumétrie : 813 234 observations à 30 req/min | Élevé | Périmètre v1 limité à FRANCE/REG/DEP ; tester la valeur max de `maxResult` |
| Pagination tronquée sans signal | Élevé | Contrôles A2 et A5, garde-fou `max_pages` |
| Notation scientifique mal parsée | Élevé | Type `Double`/`BigDecimal` + contrôle M4 |
| Confusion `PMUN` / `PSDC` dans les rapports | Élevé | Mesures DAX filtrées explicitement, rupture marquée sur la page 3 |
| Talend Open Studio arrêté depuis janvier 2024 | Élevé | Version archivée documentée, ou bascule Apache Hop |
| DELETE sans INSERT après un échec | Élevé | Transaction explicite, rollback sur branche d'erreur |
| Mémoire : 7,6 Go pour Docker | Moyen | Heap ES à 512 Mo si des conteneurs sont tués |
| Libellés géographiques absents de l'API | Moyen | Enrichissement COG en v2, ou libellés vides assumés en v1 |
| Mapping ES en `text` au lieu de numérique | Moyen | Contrôler les data views avant de construire les panneaux |
| Dérive budgétaire Power BI | Moyen | Rester en Desktop, ne jamais publier sur le Service |
| Essai Elastic payant activé par inadvertance | Moyen | `GET /_license` doit renvoyer `basic` |
| Exécutions cron qui se chevauchent | Moyen | Verrou `flock -n` |
| `.pbix` volumineux sur Git | Faible | Git LFS ou export PBIP |

---

## 13. Plan d'exécution détaillé — ordre à suivre

| # | Étape | Sous-étape | Durée | Livrable / point de sortie |
|---|---|---|---|---|
| **1** | **Socle technique** | | **2 h** | ✅ *réalisé* |
| 1.1 | | Dépôt GitHub, `.gitignore`, README, arborescence | 15 min | Dépôt structuré |
| 1.2 | | `docker-compose.yml` : Postgres, ES 8 Basic + auth, Kibana, `es-setup`, Filebeat | 45 min | Fichier compose |
| 1.3 | | `docker compose up`, résolution des erreurs de démarrage | 30 min | 3 conteneurs UP |
| 1.4 | | Mot de passe `kibana_system`, accès Kibana sur `:5601` | 15 min | Kibana authentifié |
| 1.5 | | Schémas `bronze`/`silver`/`gold`, rôles `etl_user` et `bi_reader` | 15 min | Cloisonnement en place |
| **2** | **Exploration API** | | **1 h** | ✅ *réalisé* |
| 2.1 | | Catalogue, identification du jeu | 10 min | `DS_POPULATIONS_HISTORIQUES` |
| 2.2 | | Structure d'une observation, dimensions, mesures | 15 min | 4 dimensions, 2 mesures |
| 2.3 | | Test des filtres `GEO` et `POPREF_MEASURE` | 15 min | `PTOT` inexistant confirmé |
| 2.4 | | Mécanique de pagination (`maxResult`, `page`, `isLast`) | 10 min | Stratégie While tranchée |
| 2.5 | | Décision de périmètre v1 | 10 min | FRANCE / REG / DEP |
| **3** | **Modélisation médaillon** | | **1 h 15** | |
| 3.1 | | `01_bronze.sql` : payload JSONB + colonnes de pagination | 20 min | Bronze créé |
| 3.2 | | `02_silver.sql` : table à plat avec `GEO` décomposé + `sl_rejets` | 25 min | Silver créé |
| 3.3 | | `03_gold_dimensions.sql` et `04_gold_faits.sql` | 30 min | Étoile en place |
| **4** | **Ingestion ETL** | | **4 h** | Étape la plus risquée |
| 4.1 | | Projet, `params.properties`, `params.example.properties` | 15 min | Paramétrage externalisé |
| 4.2 | | `tPreJob` : `tFileInputProperties` → `tContextLoad` → UUID | 20 min | Contexte chargé au runtime |
| 4.3 | | **Joblet `jl_log_execution`** | 40 min | Réutilisable — avant les jobs métier |
| 4.4 | | Test de `maxResult` : trouver la valeur maximale acceptée | 10 min | Nombre d'appels connu |
| 4.5 | | `tRESTClient` seul → `tLogRow` : un appel validé | 20 min | Premier JSON reçu |
| 4.6 | | Insertion du payload brut en Bronze | 25 min | Bronze alimenté |
| 4.7 | | `tExtractJSONFields` : aplatissement des observations | 40 min | Flux tabulaire correct |
| 4.8 | | `tLoop` While sur `isLast`, `max_pages`, incrémentation | 40 min | Pagination complète |
| 4.9 | | `tSleep`, branche 429, compteur de retry | 20 min | Quota respecté |
| 4.10 | | Boucle externe sur FRANCE / REG / DEP | 20 min | Périmètre v1 ingéré |
| **5** | **Transformation** | | **3 h** | |
| 5.1 | | Bronze → Silver : décomposition de `GEO`, typage `Double` | 50 min | Silver peuplé |
| 5.2 | | `dim_temps` et `dim_mesure` (petits référentiels) | 20 min | Dimensions peuplées |
| 5.3 | | `dim_geo` : niveaux FRANCE → REG → DEP avec `sk_parent` | 50 min | Hiérarchie fonctionnelle |
| 5.4 | | `f_population` : résolution des clés de substitution | 40 min | Faits chargés |
| 5.5 | | Delete-insert par `(niveau_geo, millesime)` en transaction | 20 min | Job idempotent |
| **6** | **Qualité** | | **2 h 15** | |
| 6.1 | | Table `dq_results` avec le champ `famille` | 15 min | Table créée |
| 6.2 | | Contrôles API A1 à A4 | 35 min | Extraction fiabilisée |
| 6.3 | | Contrôles API A5 à A7 (réconciliation, format, parsing) | 30 min | 7 contrôles API actifs |
| 6.4 | | Contrôles métier M1, M8, M9 (bloquants) | 25 min | Intégrité garantie |
| 6.5 | | Contrôles métier M2, M3, M4 (cohérence hiérarchique) | 30 min | Vraie valeur ajoutée |
| **7** | **Supervision** | | **2 h 30** | |
| 7.1 | | Vérification du NDJSON produit par le joblet | 15 min | Fichier valide |
| 7.2 | | Filebeat, création des 3 index | 40 min | Données dans ES |
| 7.3 | | Data views, vérification du mapping numérique | 20 min | Data views OK |
| 7.4 | | Dashboard « Santé des exécutions » | 15 min | Dashboard 1 |
| 7.5 | | Dashboard « Performance API » | 15 min | Dashboard 2 |
| 7.6 | | Dashboard « Qualité » + export `.ndjson` | 20 min | Dashboard 3 versionné |
| 7.7 | | Visualisations à forte valeur (heat map, percentiles, somme cumulée) | 30 min | Dashboards exploitables au quotidien |
| **8** | **Restitution Power BI** | | **3 h** | |
| 8.1 | | Connexion `bi_reader` en Import | 15 min | Données chargées |
| 8.2 | | Relations, hiérarchie géographique, masquage des clés | 30 min | Modèle propre |
| 8.3 | | Mesures DAX de base, filtrées par code de mesure | 25 min | Mesures socles |
| 8.4 | | Mesures temporelles (précédent, évolution, indice 100) | 40 min | Mesures d'évolution |
| 8.5 | | Page 1 — Vue d'ensemble | 25 min | Page 1 |
| 8.6 | | Page 2 — Comparaison territoriale | 30 min | Page 2 |
| 8.7 | | Page 3 — Évolution, avec rupture PSDC/PMUN marquée | 25 min | Page 3 |
| 8.8 | | Page 4 — Qualité, séparée API / métier | 25 min | Page 4 |
| **9** | **Industrialisation** | | **2 h 30** | |
| 9.1 | | Export du job, `Dockerfile` sur `eclipse-temurin:17-jre` | 40 min | Image du runner |
| 9.2 | | Job dans le réseau Docker, test de bout en bout | 30 min | Exécution conteneurisée |
| 9.3 | | Export des dashboards Kibana | 15 min | Dashboards rejouables |
| 9.4 | | Planification cron, `flock`, redirection des logs | 30 min | Chaîne automatisée |
| 9.5 | | README : architecture, prérequis, lancement, captures | 25 min | Doc lisible |
| 9.6 | | Nettoyage des secrets, `.env.example`, push | 10 min | Dépôt présentable |
| **10** | **CI/CD GitHub Actions** *(en dernier)* | | **2 h 30** | |
| 10.1 | | Workflow « hello world » | 30 min | Première action verte |
| 10.2 | | `lint-sql` avec `sqlfluff` | 30 min | SQL validé |
| 10.3 | | `build-runner` | 30 min | Image vérifiée à chaque push |
| 10.4 | | `test-ddl` : service PostgreSQL + assertions | 45 min | Dépôt déployable prouvé |
| 10.5 | | Badge de statut dans le README | 15 min | Projet présentable |
| **11** | **Extension v2** *(optionnel)* | | **+4 h** | |
| 11.1 | | Ingestion du niveau `COM` (~800 000 observations) | 2 h | Granularité complète |
| 11.2 | | Enrichissement des libellés depuis le COG | 1 h | Rapports lisibles |
| 11.3 | | Second jeu de données via `dim_mesure` | 1 h | Modèle enrichi |

**Total étapes 3 à 9 : 17 h 30. Avec la CI/CD : 20 h.** Les étapes 1 et 2 sont faites.

**Points de contrôle à ne pas franchir sans validation**
- Fin de l'étape 4.4 → la valeur max de `maxResult` est connue, sinon le volume d'appels est imprévisible
- Fin de l'étape 4.8 → la pagination se termine sur `isLast`, sinon les données sont tronquées silencieusement
- Fin de l'étape 5.1 → les valeurs en notation scientifique sont correctement typées, sinon tous les agrégats sont faux
- Fin de l'étape 6.3 → réconciliation Bronze/Silver/Gold sans écart, sinon les chiffres Power BI sont faux
