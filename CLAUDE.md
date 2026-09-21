# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Dépôt d'orchestration Docker Swarm de l'organisation Les Chauffagistes. Il ne contient pas de code applicatif — uniquement des stack files Docker Compose et des workflows CI/CD.

## Architecture Swarm

### Nœuds

| Label | Machine | Rôle |
|---|---|---|
| `node.labels.ingress == true` | VPS | Point d'entrée Traefik (ports 80/443) |
| `node.labels.chauffagistes.host == hugo` | iMac (10.10.0.3), 4 CPU / 8 Go RAM | Workloads, registry privé, héberge le staging (faible activité) — cible par défaut pour tout nouveau déploiement |
| `node.labels.chauffagistes.host == vps` | VPS | Workloads VPS |
| `node.labels.chauffagistes.host == itrider` | itrider, 4 CPU / 8 Go RAM | Workloads — capacité supplémentaire si besoin d'étaler |

### Réseaux

- **`traefik-public`** (externe) — réseau sur lequel Traefik route le trafic. Tout service exposé via Traefik **doit** y être attaché.
- **`chauffagistes-net`** (externe) — communication inter-services (DNS Swarm entre stacks).
- **`<service>-<env>-internal`** (overlay interne) — réseau isolé pour la communication app ↔ db au sein d'un même stack. La db n'est jamais sur `chauffagistes-net`, sauf les nœuds Patroni du cluster HA partagé, qui doivent y être pour joindre etcd et Garage — voir [Haute disponibilité Postgres](#haute-disponibilité-postgres-patroni--etcd).
- **`pg-<env>`** (overlay interne, créé par le stack `pg-ha-<env>`) — accès des applis au cluster Postgres HA via `pg-ha-<env>_haproxy`.

## Organisation des stacks

```
stacks/
  core/       # Traefik, registry Docker privé, YouTrack — déployés en stack unique "core"
  staging/    # Un fichier par service, déployé depuis la branche develop
  prod/       # Un fichier par service, déployé depuis la branche main
  common/     # Fichiers de config identiques entre staging et prod (jamais un stack),
              # référencés en ../common/<fichier> — ex: entrypoint et config Patroni,
              # config HAProxy de pg-ha. Y toucher redéploie les deux environnements.
  debug/      # Outils ponctuels, jamais déployés par la CI
```

## Conventions de nommage

### Stacks Swarm

La pipeline dérive le nom du stack depuis le nom du fichier suffixé de l'environnement :

```
stacks/staging/pool-site.yml  →  stack "pool-site-staging"
stacks/prod/pool-site.yml     →  stack "pool-site-prod"
stacks/core/*.yml             →  stack "core" (tous les fichiers core sont mergés)
```

### DNS inter-services (Swarm)

Deux cas distincts selon que les services sont dans le même stack ou non :

**Intra-stack** (ex: app → db dans le même fichier yml) → nom court du service :
```
# DB dans le même stack
DB_HOST: db
```

**Inter-stack** (via `chauffagistes-net`, vers un service d'un autre stack) → format `<stack>_<service>` :
```
# App de auth-service-back depuis un autre stack
AUTH_SERVICE_URL: auth-service-back-staging_app:8080/auth
```

### Secrets

Format : `<service_snake_case>_<env>_<type>` — ex : `pool_site_staging_db_password`, `coins_staging_api_key`.

Les secrets sont créés manuellement sur le manager Swarm et ne transitent jamais par Git :

```bash
printf "valeur" | docker secret create pool_site_staging_db_password -
```

### Images

- Staging : tag `sha-<7chars>` (ex: `sha-52acb7a`)
- Prod : tag semver obligatoire (ex: `1.2.3`) — la CI bloque les SHA en prod
- Registry privé : `10.10.0.3:5000/<service>:<tag>` (toujours ce registre, pas ghcr.io)

## CI/CD

### `build.yml` — workflow réutilisable

Appelé depuis les repos des services applicatifs. Construit et pousse l'image sur `10.10.0.3:5000`. Tourne sur le runner `[self-hosted, worker]`.

```yaml
uses: chauffagistes/chauffagistes-orchestration/.github/workflows/build.yml@main
with:
  service-name: mon-service
  build-target: runner   # optionnel, pour multi-stage
secrets:
  REGISTRY_USER: ${{ secrets.REGISTRY_USER }}
  REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
```

### `deploy.yml` — déploiement automatique

Déclenché sur push `develop` (staging) et `main` (prod). Étapes :

1. **Guard** (prod uniquement) — vérifie qu'aucune image dans `stacks/prod/` ne porte un tag `sha-` ou `branch-`
2. **Deploy core** — `docker stack deploy` de tous les fichiers `stacks/core/*.yml` sous le nom `core`
3. **Pre-pull** (prod uniquement) — `.github/scripts/prepull-images.sh` fait télécharger les images du registry privé référencées dans `stacks/prod/` sur tous les nœuds `workload == true` (un service Swarm `global-job` par image), pour qu'un nœud puisse reprendre les services d'un autre même si le registry est injoignable. Non bloquant
4. **Deploy services** — itère sur `stacks/<env>/*.yml`, nom du stack = `<fichier>-<env>`
5. **Verify convergence** — attend que tous les services atteignent leur nombre de replicas cible (timeout 120s, 180s pour core)

## Ajouter un nouveau service

1. Choisir le template dans `_templates/` selon le besoin (avec/sans DB, exposé ou non)
2. Copier en `stacks/staging/<service>.yml` et `stacks/prod/<service>.yml`
3. Remplacer `MY-SERVICE` (kebab-case) et `MY_SERVICE` (snake_case) partout
4. Créer les secrets sur le manager Swarm
5. Ajouter le workflow `build.yml` dans le repo du service
6. Committer — la CI déploie automatiquement

## Haute disponibilité Postgres (Patroni + etcd)

Un cluster Postgres HA **partagé par environnement** (`stacks/<env>/pg-ha.yml` → stack
`pg-ha-<env>`), qui héberge une base + un rôle par microservice. Remplace à terme les db pinnées
du template `with-db` (migration en cours, staging d'abord).

- `db1` (hugo) / `db2` (itrider) : Patroni + `timescaledb-ha:pg17`, un par domicile. Si un nœud
  tombe, l'autre prend le primaire.
- DCS : cluster etcd partagé `etcd-dcs-<env>` (3 membres : hugo, vps, itrider ; le VPS départage).
  `failsafe_mode` garde le primaire en écriture si etcd perd son quorum.
- `haproxy` (2 réplicas, un par nœud workload) route vers le primaire (`GET /primary` sur l'API
  Patroni). Les applis rejoignent le réseau externe `pg-<env>` avec `DB_HOST: pg-ha-<env>_haproxy`.
- DataGrip : port publié par HAProxy sur hugo et itrider (5451 en staging), utilisateur `postgres`.
- API REST Patroni : les endpoints qui modifient l'état (switchover, restart...) exigent
  l'utilisateur `patroni` + le secret `pg_ha_<env>_restapi_password`.

Mesuré en staging : bascule planifiée ~8 s de coupure d'écriture, arrêt propre d'un nœud ~10 s,
crash brutal du primaire ~40 s (expiration du verrou etcd, `ttl: 30`), perte du quorum etcd 0 s.

### Sauvegardes

barman-cloud vers Garage (bucket `pg-<env>`, endpoint `http://garage:3900`) : archivage WAL en
continu + sauvegarde complète quotidienne lancée par le primaire du moment (`stacks/common/pg-ha-entrypoint.sh`),
avec rétention. Restauration à un instant donné validée en staging. Alertes Loki `PgBackupFailed`,
`PgWalArchiveFailed`, `PgBackupMissing*`.

pgBackRest (aussi présent dans l'image) n'est pas utilisé : il n'accepte que du S3 en HTTPS, Garage
est en HTTP sur le réseau interne.

### Pièges

- **Healthcheck et DNS** : Swarm ne publie une tâche dans son DNS (et son VIP) qu'une fois son
  healthcheck `healthy`. Un service qui découvre ses pairs par DNS ne doit pas avoir un healthcheck
  qui dépend de ces pairs (deadlock au bootstrap : c'est pour ça qu'etcd n'en a pas), ni un
  healthcheck qui échoue pendant une phase longue normale. Patroni utilise donc `/liveness`, pas
  `/health` (qui échoue pendant la copie initiale d'un replica).
- **HAProxy** : résout `db1`/`db2` en continu via le DNS Swarm (`resolvers`), et démarre ses
  serveurs `init-state down` (HAProxy ≥ 3.1) pour ne jamais router vers un replica avant le premier
  check.
- **Mise à jour simultanée** : un `docker stack deploy` qui modifie `db1` **et** `db2` (ex. un fichier de
  `stacks/common/`) les redémarre en même temps → coupure complète le
  temps du redémarrage. En prod, passer ces changements hors des heures actives.
- **Fichiers annexes** : la CI déploie chaque `stacks/<env>/*.yml` comme un stack. Les fichiers de
  config d'un stack doivent donc être en `.yaml`, `.cfg`, `.sh`...
- **botocore** (barman-cloud) rejette les hôtes contenant `_` : d'où l'alias réseau `garage` pour
  `core_garage`.
- **Volumes** : les données etcd/Patroni survivent à `docker stack rm`. Un membre qui a bootstrappé
  avec une mauvaise config réutilise cet état : après un fix de config qui ne converge pas, vider
  les volumes.

## Monitoring

Stack d'observabilité dans `stacks/core/` : Prometheus (métriques, service discovery Swarm natif
via `dockerswarm_sd_configs`) + Loki/Promtail (logs) + Alertmanager (routage Discord, avec le sidecar
`alertmanager-discord` qui reformate le webhook générique "slack" au format Discord) + Grafana
(dashboards + Explore). `node-exporter` et `cadvisor` tournent en `mode: global` sur tous les nœuds.

### Secrets requis

```bash
# Sur le manager, une seule fois
printf "<mot de passe fort>" | docker secret create core_grafana_admin_password -
```

`alertmanager-discord` tourne sur une image `FROM scratch` (pas de shell dedans) : impossible d'y
injecter un secret Docker via le wrapper `sh -c export $(cat ...)` utilisé ailleurs. Le webhook
Discord est donc passé en flag CLI (`-webhook.url=${DISCORD_WEBHOOK_URL}`) interpolé par Compose au
moment du `docker stack deploy`, exactement comme `TRAEFIK_DASHBOARD_AUTH` pour Traefik — c'est un
**secret d'environnement GitHub Actions** (`DISCORD_WEBHOOK_URL`, environnements `Staging` et
`Production`), pas un secret Docker Swarm :

```bash
gh secret set DISCORD_WEBHOOK_URL -R Les-Chauffagistes/deploy --env staging
gh secret set DISCORD_WEBHOOK_URL -R Les-Chauffagistes/deploy --env production
```

### Faire remonter les métriques d'un microservice

Ajouter ces labels Swarm dans `deploy.labels` du service (comme pour Traefik) :

```yaml
labels:
  - "prometheus.scrape=true"
  - "prometheus.port=8086"
  # - "prometheus.path=/metrics"  # optionnel, défaut /metrics
```

Prometheus le détecte automatiquement au prochain cycle de service discovery, pas besoin de toucher
`stacks/core/prometheus.config.yml`.

### Alertes déjà en place

- `ContainerRestartLoop` / `ServiceReplicasDown` (Prometheus, cAdvisor + `up`)
- `ContainerMemoryNearLimit` / `NodeDiskSpaceLow` (Prometheus, node-exporter/cAdvisor)
- `HighErrorLogRate` (Loki ruler, sur le label `level` extrait des logs JSON — voir
  ci-dessous) / `HighErrorLogRateLegacy` (idem mais par regex texte, pour les
  services qui n'émettent pas encore de JSON)

Toutes routées vers Discord via Alertmanager. Ajouter une règle : éditer
`stacks/core/prometheus.rules.yaml` (métriques) ou `stacks/core/loki.rules.yaml` (logs).

### Logs JSON et détection d'erreurs

Les 5 services Python (loguru, `src/modules/logger/logger.py`) émettent leur sortie stdout en JSON
(`serialize=True`) plutôt qu'en texte colorisé. C'est nécessaire pour l'alerting : en texte, une
seule exception avec stack trace produit plusieurs lignes contenant `error`, et l'ancienne règle
regex comptait chaque ligne comme une occurrence séparée (une seule exception pouvait déclencher
`HighErrorLogRate`). En JSON, une exception = une ligne = un événement, stack trace incluse dans le
champ `record.exception`.

Promtail (`stacks/core/promtail.config.yaml`) parse cette sortie JSON pour en extraire le niveau et
le poser en label Loki `level`. `HighErrorLogRate` compte les événements `level=~"ERROR|CRIT"` —
plus fiable qu'un pattern texte. Les services qui n'émettent pas de JSON (les 4 apps Next.js, encore
en `console.*` brut) n'ont pas ce label : ils restent couverts par `HighErrorLogRateLegacy`, qui
reprend l'ancien comptage par ligne (moins précis, faux positifs possibles sur une stack trace
multi-lignes) tant qu'ils ne sont pas migrés au JSON.

Migration en cours vers le wrapper commun `chauff-cmn` (`chauff_cmn.logging`), qui remplace le
module maison dupliqué dans les 5 services. Le module maison produit un JSON imbriqué
(`record.level.name`), `chauff-cmn` produit un JSON plat (`level` à la racine). Promtail extrait les
deux formats en parallèle le temps que tous les services migrent (voir commentaire dans
`promtail.config.yaml`).

## Traefik

- Tourne exclusivement sur le nœud `ingress` (VPS)
- Route uniquement vers les services sur `traefik-public` (`--providers.swarm.network=traefik-public`)
- Les labels Traefik se mettent dans `deploy.labels` (pas dans `labels` racine) pour être lus par Swarm
- TLS via Let's Encrypt (resolver `letsencrypt`, challenge HTTP)
- Toutes les requêtes HTTP sont redirigées vers HTTPS automatiquement
