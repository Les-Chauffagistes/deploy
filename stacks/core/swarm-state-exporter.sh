#!/bin/sh
# Interroge l'API Swarm (docker node ls) depuis le manager et écrit les
# métriques dans le répertoire textfile collector de node-exporter (voir
# node-exporter.yml, --collector.textfile.directory), pour que Prometheus
# voie l'état des nœuds même quand ils sont Down/Drain — contrairement à
# node-exporter/cAdvisor (mode: global), qui n'ont tout simplement plus de
# tâche du tout sur un nœud drainé, donc plus aucune métrique.
set -eu

OUT_FILE=/textfile/swarm_nodes.prom
TMP_FILE="$OUT_FILE.tmp"
INTERVAL="${INTERVAL:-30}"

while true; do
  {
    echo '# HELP swarm_node_info Info statique sur un nœud Swarm (docker node ls). Valeur toujours 1.'
    echo '# TYPE swarm_node_info gauge'
    echo '# HELP swarm_node_ready Le Status.State du nœud Swarm est Ready (1) ou non (0).'
    echo '# TYPE swarm_node_ready gauge'
    echo '# HELP swarm_node_active La disponibilité du nœud Swarm est Active (1) ou non — Pause/Drain (0).'
    echo '# TYPE swarm_node_active gauge'

    docker node ls --format '{{.Hostname}}|{{.Status}}|{{.Availability}}|{{.ManagerStatus}}' |
      while IFS='|' read -r hostname status availability manager_status; do
        [ -z "$hostname" ] && continue
        ready=0
        [ "$status" = "Ready" ] && ready=1
        active=0
        [ "$availability" = "Active" ] && active=1
        printf 'swarm_node_info{node="%s",status="%s",availability="%s",manager_status="%s"} 1\n' \
          "$hostname" "$status" "$availability" "$manager_status"
        printf 'swarm_node_ready{node="%s"} %s\n' "$hostname" "$ready"
        printf 'swarm_node_active{node="%s"} %s\n' "$hostname" "$active"
      done
  } > "$TMP_FILE"
  # Écriture atomique : node-exporter relit périodiquement le répertoire,
  # un mv évite qu'il tombe sur un fichier à moitié écrit.
  mv "$TMP_FILE" "$OUT_FILE"
  sleep "$INTERVAL"
done
