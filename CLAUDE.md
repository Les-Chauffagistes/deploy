# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Dépôt d'orchestration Docker Swarm de l'organisation Les Chauffagistes. Il ne contient pas de code applicatif — uniquement des stack files Docker Compose et des workflows CI/CD.

## Architecture Swarm

### Nœuds

| Label | Machine | Rôle |
|---|---|---|
| `node.labels.ingress == true` | VPS | Point d'entrée Traefik (ports 80/443) |
| `node.labels.chauffagistes.host == hugo` | iMac (10.10.0.3) | Workloads et registry privé |
| `node.labels.chauffagistes.host == vps` | VPS | Workloads VPS |

### Réseaux

- **`traefik-public`** (externe) — réseau sur lequel Traefik route le trafic. Tout service exposé via Traefik **doit** y être attaché.
- **`chauffagistes-net`** (externe) — communication inter-services (DNS Swarm entre stacks).
- **`<service>-<env>-internal`** (overlay interne) — réseau isolé pour la communication app ↔ db au sein d'un même stack. La db n'est jamais sur `chauffagistes-net`.

## Organisation des stacks

```
stacks/
  core/       # Traefik, registry Docker privé, YouTrack — déployés en stack unique "core"
  staging/    # Un fichier par service, déployé depuis la branche develop
  prod/       # Un fichier par service, déployé depuis la branche main
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
3. **Deploy services** — itère sur `stacks/<env>/*.yml`, nom du stack = `<fichier>-<env>`
4. **Verify convergence** — attend que tous les services atteignent leur nombre de replicas cible (timeout 120s, 180s pour core)

## Ajouter un nouveau service

1. Choisir le template dans `_templates/` selon le besoin (avec/sans DB, exposé ou non)
2. Copier en `stacks/staging/<service>.yml` et `stacks/prod/<service>.yml`
3. Remplacer `MY-SERVICE` (kebab-case) et `MY_SERVICE` (snake_case) partout
4. Créer les secrets sur le manager Swarm
5. Ajouter le workflow `build.yml` dans le repo du service
6. Committer — la CI déploie automatiquement

## Traefik

- Tourne exclusivement sur le nœud `ingress` (VPS)
- Route uniquement vers les services sur `traefik-public` (`--providers.swarm.network=traefik-public`)
- Les labels Traefik se mettent dans `deploy.labels` (pas dans `labels` racine) pour être lus par Swarm
- TLS via Let's Encrypt (resolver `letsencrypt`, challenge HTTP)
- Toutes les requêtes HTTP sont redirigées vers HTTPS automatiquement
