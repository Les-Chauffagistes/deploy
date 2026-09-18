# Ajouter un nouveau microservice

## 1. Choisir le bon template

| Situation | Template |
|---|---|
| Service avec PostgreSQL, **non exposé** (ex: HeatCoin) | `_templates/with-db.staging.yml` + `with-db.prod.yml` |
| Service avec PostgreSQL + routes publiques | `_templates/with-db-exposed.staging.yml` + `with-db-exposed.prod.yml` |
| Service avec PostgreSQL **en haute disponibilité** (survit à la panne d'un nœud) | `_templates/with-db-ha.staging.yml` + `with-db-ha.prod.yml` |
| Service sans DB (ex: frontend NextJS) | `_templates/no-db.staging.yml` + `no-db.prod.yml` |

> Le template HA (Patroni + HAProxy sur DCS etcd partagé) demande plus de nœuds/conteneurs et
> une vraie procédure de bascule à tester avant mise en prod — voir la section dédiée plus bas.
> Pour un service secondaire ou peu critique, `with-db.staging.yml` reste le bon choix par défaut.

---

## 2. Créer les stack files

```bash
# Exemple pour un service "share-viewer"
cp stacks/_templates/no-db.staging.yml stacks/staging/share-viewer.yml
cp stacks/_templates/no-db.prod.yml    stacks/prod/share-viewer.yml
```

Remplacer dans les deux fichiers :
- `MY-SERVICE` → `share-viewer` (kebab-case, utilisé dans les noms Docker et les routes Traefik)
- `MY_SERVICE` → `share_viewer` (snake_case, utilisé dans les noms de secrets)
- `app` n'est pas pinné à un nœud (Swarm choisit) — seul `db` doit rester pinné, à cause de
  son volume local (voir "Répartition des nœuds" ci-dessous)

---

## 3. Créer les secrets sur le manager Swarm

```bash
# Staging
printf "mot_de_passe_fort" | docker secret create share_viewer_staging_api_key -

# Prod
printf "mot_de_passe_fort" | docker secret create share_viewer_prod_api_key -

# Pour les services avec DB, créer aussi :
# share_viewer_staging_db_password
# share_viewer_prod_db_password
```

> Les secrets sont créés **une seule fois** sur le manager.
> Ils ne transitent jamais par Git.

---

## 4. Ajouter le CI dans le repo du service

Copier `.github/workflows/ci.yml` depuis un autre repo service et adapter :

```yaml
jobs:
  build-push:
    uses: chauffagistes/chauffagistes-orchestration/.github/workflows/reusable-build-push.yml@main
    with:
      service-name: share-viewer   # ← nom de l'image GHCR
    secrets:
      ORG_PAT: ${{ secrets.ORG_PAT }}
```

---

## 5. Répartition des nœuds

Les labels sont appliqués **une seule fois** sur le manager, indépendamment des stack files :

```bash
docker node update --label-add chauffagistes.host=hugo      iMac-de-Hugo
docker node update --label-add chauffagistes.host=itrider   itrider
```

Pour déplacer un service d'un nœud à l'autre :
1. Modifier `node.labels.chauffagistes.host` dans le stack file
2. Si le service a une DB avec volume : migrer les données d'abord (voir ci-dessous)
3. Committer et pusher

### Migrer un volume PostgreSQL entre nœuds

```bash
# 1. Dump sur l'ancien nœud
docker exec <container_db> pg_dump -U MY_SERVICE MY_SERVICE > backup.sql

# 2. Mettre à jour le placement constraint dans le stack file et déployer
#    → Swarm crée un nouveau container db sur le nouveau nœud (volume vide)

# 3. Restaurer sur le nouveau nœud
docker exec -i <nouveau_container_db> psql -U MY_SERVICE MY_SERVICE < backup.sql
```

---

## 6. Cas particulier : template `with-db-ha`

Diffère des autres templates sur trois points :

- **Prérequis** : le cluster etcd partagé de l'environnement doit déjà être déployé
  (`stacks/staging/etcd.yml` / `stacks/prod/etcd.yml`, stacks `etcd-staging` / `etcd-prod`) —
  c'est le DCS (Distributed Consensus Store) que Patroni utilise pour élire le primaire.
  Un seul etcd pour tous les services HA d'un environnement, pas un par service.
- **Fichier en plus à copier** : `_templates/with-db-ha-haproxy.cfg` → `stacks/<env>/MY-SERVICE-haproxy.cfg`
  (contenu générique, pas de placeholder à remplacer dedans). C'est la config Swarm référencée par le
  service `haproxy` du stack file.
- **Secret en plus à créer** : en plus de `db_password` et `api_key`, il faut
  `MY_SERVICE_<env>_db_replication_password` (mot de passe du rôle de réplication Postgres interne,
  jamais utilisé par l'app).
- `db1`/`db2` sont pinnés chacun sur un nœud physique différent (pas le même nœud que l'app, qui n'a
  plus besoin d'être pinnée du tout — elle passe toujours par `haproxy`, qui route vers le primaire
  du moment). Voir les commentaires en tête de `with-db-ha.staging.yml` pour le détail.

Avant tout passage en prod : tester une vraie bascule (arrêter le nœud qui porte le primaire, vérifier
que `haproxy` reroute automatiquement vers l'autre nœud et que l'app reste disponible).

---

## Conventions de nommage

| Élément | Format | Exemple |
|---|---|---|
| Nom image GHCR | kebab-case | `share-viewer` |
| Nom stack Swarm | kebab-case | `share-viewer` |
| Nom secret | snake_case + env | `share_viewer_prod_api_key` |
| Réseau interne | kebab-case + env | `share-viewer-prod-internal` |
| Volume DB | kebab-case + env | `share-viewer-prod-db-data` |
| Route Traefik staging | `service.staging.domain.com` | `share-viewer.staging.example.com` |
| Route Traefik prod | `service.domain.com` | `share-viewer.example.com` |