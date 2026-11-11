# ChauffAssistant cloud — staging

URL : https://chauffassistant-backend.staging.chauffagistes-btc.fr

Le service `chauffassistant-backend-staging_app` s’exécute sur le VPS, sans accès
aux équipements locaux. Cette première étape est le socle HTTP ; authentification
avec les comptes Chauffagistes et relais des installations sont encore à implémenter.
Les endpoints publics indiquent explicitement `remote_access_enabled: false`.

La branche `develop` déclenche le workflow Deploy :

1. Lecture du commit `x-chauffassistant-source-ref` et validation du tag image associé.
2. Checkout de ce commit dans le dépôt privé `Les-Chauffagistes/ChauffAssistant`.
3. Tests du serveur cloud, build `Dockerfile.cloud`, push vers le registry privé.
4. Déploiement et convergence des stacks staging existantes, dont ce nouveau service.
5. Vérification HTTPS de la révision et absence des API de matériel local.

Secrets GitHub utilisés par la CI : `ORG_PAT` (lecture du dépôt source privé),
`REGISTRY_USER`, `REGISTRY_PASSWORD`. Aucun nouveau secret Swarm n’est requis
pour cette première étape. Le secret ORG_PAT est déjà utilisé ailleurs dans ce dépôt ;
il doit aussi autoriser la lecture de ChauffAssistant.

Mettre à jour la référence de 40 caractères et le tag `sha-<7 caractères>` ensemble.
Publier le commit source **avant** le push de la stack. Si le build échoue, le job
de déploiement est bloqué et les services déjà en place ne sont pas modifiés.
Aucun fichier de production n’est ajouté ni modifié pour ce service.
