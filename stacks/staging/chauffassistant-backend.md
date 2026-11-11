# ChauffAssistant cloud — staging

URL : https://api.chauffassistant.staging.chauffagistes-btc.fr

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

Le build est exécuté dans le dépôt ChauffAssistant par le workflow **Cloud image**,
qui teste le relais puis appelle `deploy/.github/workflows/build.yml` avec
`Dockerfile.cloud`. Le workflow réutilisable publie l’image dans le registry privé.
Les index privés npm/pip sont désactivés pour ce service Go.

Le déploiement suit le fonctionnement commun aux autres applications : après
publication de l’image, mettre à jour uniquement son tag `sha-<7 caractères>`
dans `stacks/staging/chauffassistant-backend.yml`, puis pousser sur `develop`.
Le workflow commun déploie les stacks staging et vérifie leur convergence Swarm.
Il ne consulte pas le dépôt applicatif ni sa CI et n’attend pas son build.
Le healthcheck du conteneur participe à la vérification de convergence standard.

Les secrets `REGISTRY_USER` et `REGISTRY_PASSWORD` sont configurés dans le dépôt
applicatif pour son build. Leur configuration et leur rotation sont gérées hors
du workflow de déploiement, comme pour les autres applications.

Nom canonique : `api.chauffassistant.staging.chauffagistes-btc.fr`.
L’ancien nom reste un alias pour les agents déjà associés. Le volume et les
associations sont conservés ; il n’y a ni renommage du service ni migration de données.
L’authentification reste strictement staging.

Aucun fichier de production n’est ajouté pour ce service.
