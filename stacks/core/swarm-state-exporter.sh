#!/bin/sh
# Interroge l'API Swarm (docker node ls, docker service ls) depuis le manager
# et écrit les métriques dans le répertoire textfile collector de node-exporter
# (voir node-exporter.yml, --collector.textfile.directory), pour que Prometheus
# voie l'état des nœuds et des services même quand ils sont Down/Drain/à 0
# réplica — contrairement à node-exporter/cAdvisor (mode: global), qui n'ont
# tout simplement plus de tâche du tout sur un nœud drainé, donc plus aucune
# métrique, et à up{}, qui ne dit rien d'un service sans aucune tâche.
set -eu

OUT_FILE=/textfile/swarm_nodes.prom
TMP_FILE="$OUT_FILE.tmp"
INTERVAL="${INTERVAL:-30}"

while true; do
  # Les deux appels doivent réussir avant de réécrire le fichier : sans leader
  # Swarm (ou manager injoignable), on laisse l'ancien fichier vieillir —
  # SwarmStateStale (prometheus.rules.yaml) le détecte — plutôt que de publier
  # un fichier vide dont l'absence de séries ferait résoudre silencieusement
  # toutes les alertes SwarmNode*/SwarmService*.
  if nodes=$(docker node ls --format '{{.Hostname}}|{{.Status}}|{{.Availability}}|{{.ManagerStatus}}') &&
     services=$(docker service ls --format '{{.Name}}|{{.Mode}}|{{.Replicas}}'); then
    {
      echo '# HELP swarm_node_info Info statique sur un nœud Swarm (docker node ls). Valeur toujours 1.'
      echo '# TYPE swarm_node_info gauge'
      echo '# HELP swarm_node_ready Le Status.State du nœud Swarm est Ready (1) ou non (0).'
      echo '# TYPE swarm_node_ready gauge'
      echo '# HELP swarm_node_active La disponibilité du nœud Swarm est Active (1) ou non — Pause/Drain (0).'
      echo '# TYPE swarm_node_active gauge'
      echo '# HELP swarm_service_replicas_running Réplicas en cours d exécution (docker service ls, premier nombre de REPLICAS).'
      echo '# TYPE swarm_service_replicas_running gauge'
      echo '# HELP swarm_service_replicas_desired Réplicas voulus (docker service ls, second nombre de REPLICAS).'
      echo '# TYPE swarm_service_replicas_desired gauge'

      printf '%s\n' "$nodes" |
        while IFS='|' read -r hostname status availability manager_status; do
          [ -z "$hostname" ] && continue
          ready=0
          [ "$status" = "Ready" ] && ready=1
          active=0
          [ "$availability" = "Active" ] && active=1
          printf 'swarm_node_info{swarm_node="%s",status="%s",availability="%s",manager_status="%s"} 1\n' \
            "$hostname" "$status" "$availability" "$manager_status"
          printf 'swarm_node_ready{swarm_node="%s"} %s\n' "$hostname" "$ready"
          printf 'swarm_node_active{swarm_node="%s"} %s\n' "$hostname" "$active"
        done

      printf '%s\n' "$services" |
        while IFS='|' read -r name mode replicas; do
          [ -z "$name" ] && continue
          # Services "job" (ex. prepull des images en prod) : 0/N tant qu'ils
          # n'ont rien à faire, ce n'est pas une anomalie.
          case "$mode" in *job) continue ;; esac
          # "2/2" ou "2/2 (max 1 per node)" -> "2/2"
          counts="${replicas%% *}"
          printf 'swarm_service_replicas_running{swarm_service="%s"} %s\n' "$name" "${counts%%/*}"
          printf 'swarm_service_replicas_desired{swarm_service="%s"} %s\n' "$name" "${counts##*/}"
        done
    } > "$TMP_FILE"
    # Écriture atomique : node-exporter relit périodiquement le répertoire,
    # un mv évite qu'il tombe sur un fichier à moitié écrit.
    mv "$TMP_FILE" "$OUT_FILE"
  fi
  sleep "$INTERVAL"
done
