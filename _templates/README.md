# Ajouter un nouveau microservice

## 1. Choisir le bon template

| Situation | Template |
|---|---|
| Service avec PostgreSQL, **non exposé** (ex: HeatCoin) | `_templates/with-db.staging.yml` + `with-db.prod.yml` |
| Service avec PostgreSQL + routes publiques | `_templates/with-db-exposed.staging.yml` + `with-db-exposed.prod.yml` |
| Service sans DB (ex: frontend NextJS) | `_templates/no-db.staging.yml` + `no-db.prod.yml` |

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
- Ajuster `node.labels.chauffagistes.host` selon la répartition de charge souhaitée

---

## 3. Créer les secrets sur le manager Swarm

```bash
# Staging
echo "mot_de_passe_fort" | docker secret create share_viewer_staging_api_key -

# Prod
echo "mot_de_passe_fort" | docker secret create share_viewer_prod_api_key -

# Pour les services avec DB, créer aussi :
# share_viewer_staging_db_password
# share_viewer_prod_db_password
```

> Les secrets sont créés **une seule fois** sur le manager.
> Ils ne transitent jamais par Git.

---

## 4. Déclarer le déploiement dans deploy.yml

Dans `.github/workflows/deploy.yml`, ajouter un step dans le job `deploy` :

```yaml
- name: Deploy share-viewer
  run: |
    docker stack deploy \
      -c stacks/${{ github.ref == 'refs/heads/main' && 'prod' || 'staging' }}/share-viewer.yml \
      --with-registry-auth \
      --detach=false \
      share-viewer
```

---

## 5. Ajouter le CI dans le repo du service

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

## 6. Répartition des nœuds

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