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

La branche `develop` de ce dépôt ne fait que déployer :

1. Validation du commit de 40 caractères et du tag image associé.
2. Vérification que l’image est publiée (attente bornée si le build est encore en cours).
3. Déploiement et convergence des stacks staging, dont ce service.
4. Vérification HTTPS, révision et authentification obligatoire.

Nom canonique : `api.chauffassistant.staging.chauffagistes-btc.fr`.
L’ancien nom reste un alias pour les agents déjà associés. Le volume et les
associations sont conservés ; il n’y a ni renommage du service ni migration de données.
L’authentification reste strictement staging.

Le build utilise `REGISTRY_USER` et `REGISTRY_PASSWORD` dans le dépôt source.
Le déploiement utilise l’accès au registry du manager et les secrets existants
pour ses opérations habituelles. Aucun code source n’est récupéré par Deploy.
Aucun nouveau secret Swarm ni partage du secret JWT n’est nécessaire.

Mettre à jour la référence de 40 caractères et le tag `sha-<7 caractères>` ensemble,
après publication de l’image. Le déploiement échoue avant de modifier les stacks
si l’image n’est pas disponible. Aucun fichier de production n’est ajouté pour ce service.
