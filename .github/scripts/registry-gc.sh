#!/usr/bin/env bash
# Garbage-collect du registre. Le registre tourne sur hugo ; docker exec
# depuis le manager ne l'atteint pas, donc on passe par un service Swarm
# éphémère contraint à hugo avec le socket Docker monté.
set -uo pipefail

TIMEOUT=300
run_id="$(date +%s)"
name="registry-gc-${run_id}"
cleanup() { docker service rm "$name" >/dev/null 2>&1; }
trap cleanup EXIT

docker service create --detach --quiet --name "$name" \
  --constraint "node.labels.chauffagistes.host == hugo" \
  --restart-condition none \
  --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
  docker:27-cli sh -c '
    CID=$(docker ps -q -f label=com.docker.swarm.service.name=core_registry)
    docker exec "$CID" registry garbage-collect /etc/docker/registry/config.yml
  ' >/dev/null

deadline=$((SECONDS + TIMEOUT))
while :; do
  state=$(docker service ps "$name" --format '{{.CurrentState}}' 2>/dev/null | head -1)
  case "$state" in
    Complete*)
      echo "✓ garbage-collect terminé"
      docker service logs "$name" 2>&1
      exit 0
      ;;
    Failed*|Rejected*)
      echo "::error::garbage-collect a échoué: $state"
      docker service logs "$name" 2>&1
      exit 1
      ;;
  esac
  if [ $SECONDS -ge $deadline ]; then
    echo "::error::timeout garbage-collect"
    exit 1
  fi
  sleep 3
done
