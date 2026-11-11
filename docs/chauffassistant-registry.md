# Registry du build ChauffAssistant

Le dépôt source `Les-Chauffagistes/ChauffAssistant` utilise les deux secrets
`REGISTRY_USER` et `REGISTRY_PASSWORD` réutilisés depuis `deploy`, conformément
à l’autorisation de l’utilisateur. Les valeurs sont transmises directement à
l’API GitHub après chiffrement sealed-box avec la clé publique du dépôt cible.
Elles ne figurent ni dans Git ni dans les logs. `ORG_PAT` sert uniquement à
appeler l’API et n’est jamais copié vers ChauffAssistant.

Le workflow **Configure ChauffAssistant registry** est désormais manuel. En cas
de rotation des identifiants dans `deploy`, il peut être lancé pour :

1. Tester le chiffrement et la restriction aux deux noms autorisés avec des valeurs fictives.
2. Synchroniser exclusivement les deux secrets du registry vers ChauffAssistant.
3. Déclencher **Cloud image** dans le dépôt source et vérifier sa publication.

La dépendance PyNaCl est installée avant les étapes recevant les secrets.
Les identifiants du registry ne sont fournis qu’à l’étape de synchronisation ;
ils ne sont pas nécessaires au déclenchement ni au suivi du build.

Ce workflow ne construit pas d’image lui-même, ne déploie aucun service et ne
modifie pas le tag de la stack. Le build reste dans ChauffAssistant et appelle
le workflow de build réutilisable. Deploy ne fait que vérifier et déployer
une image déjà publiée. Les droits du token ORG_PAT doivent permettre la gestion
des secrets et le déclenchement des workflows dans le dépôt cible.
