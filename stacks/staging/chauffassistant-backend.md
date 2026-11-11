# ChauffAssistant cloud — staging

URL : https://chauffassistant-backend.staging.chauffagistes-btc.fr

Le service `chauffassistant-backend-staging_app` s’exécute sur le VPS, sans accès
aux équipements locaux. Le service réutilise l’authentification Chauffagistes et relaie les requêtes
vers les agents sortants des installations explicitement associées.
Les endpoints publics indiquent `remote_access_enabled: true` ; les API de compte,
d’association et de relais exigent une authentification. Le matériel local n’est
jamais disponible directement sur les routes publiques historiques.

Le volume `chauffassistant_cloud_state` conserve les sessions hachées et les
associations dans `/state`, propriétaire UID 65532. Une seule réplique doit être
utilisée ; les files de relais et les confirmations de connexion sont en mémoire.
Le service d’authentification existant est joint via le réseau Swarm. Aucun secret
JWT n’est copié dans ChauffAssistant et aucune nouvelle base de comptes n’est créée.

La branche `develop` déclenche le workflow Deploy :

1. Lecture du commit `x-chauffassistant-source-ref` et validation du tag image associé.
2. Checkout de ce commit dans le dépôt privé `Les-Chauffagistes/ChauffAssistant`.
3. Tests du serveur cloud, build `Dockerfile.cloud`, push vers le registry privé.
4. Déploiement et convergence des stacks staging existantes, dont ce nouveau service.
5. Vérification HTTPS de la révision et absence des API de matériel local.

Secrets GitHub utilisés par la CI : `ORG_PAT` (lecture du dépôt source privé),
`REGISTRY_USER`, `REGISTRY_PASSWORD`. Aucun nouveau secret Swarm n’est requis
pour ce service. Le secret ORG_PAT est déjà utilisé ailleurs dans ce dépôt ;
il doit aussi autoriser la lecture de ChauffAssistant.

Mettre à jour la référence de 40 caractères et le tag `sha-<7 caractères>` ensemble.
Publier le commit source **avant** le push de la stack. Si le build échoue, le job
de déploiement est bloqué et les services déjà en place ne sont pas modifiés.
Aucun fichier de production n’est ajouté ni modifié pour ce service.
