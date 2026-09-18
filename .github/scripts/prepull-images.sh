#!/usr/bin/env bash
# Pré-télécharge sur tous les nœuds workload les images de notre registry
# référencées par les stack files passés en argument, via un service Swarm
# global-job par image (pas besoin d'accès SSH aux nœuds). Si le nœud qui
# héberge le registry tombe, les autres ont déjà les images en cache.
#
# Usage : prepull-images.sh stacks/prod/*.yml
set -uo pipefail

REGISTRY="10.10.0.3:5000"
TIMEOUT=600

mapfile -t images < <(grep -hoE "^\s*image:\s*${REGISTRY//./\\.}/[^[:space:]\"'#]+" "$@" \
  | sed -E 's/^\s*image:\s*//' | sort -u)
[ ${#images[@]} -eq 0 ] && { echo "Aucune image $REGISTRY trouvée"; exit 0; }

run_id="$(date +%s)"
jobs=()
cleanup() { for j in "${jobs[@]}"; do docker service rm "$j" >/dev/null 2>&1; done; }
trap cleanup EXIT

for image in "${images[@]}"; do
  repo="${image#"$REGISTRY"/}"
  name="prepull-${run_id}-${repo%%[:@]*}"
  if docker service create --detach --quiet --name "$name" --mode global-job \
      --constraint "node.labels.workload == true" --with-registry-auth \
      --restart-condition none --entrypoint true "$image" >/dev/null; then
    jobs+=("$name")
    echo "→ $image"
  else
    echo "::warning::Impossible de créer le job de pré-téléchargement pour $image"
  fi
done

failed=0
deadline=$((SECONDS + TIMEOUT))
for j in "${jobs[@]}"; do
  image=$(docker service inspect "$j" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
  while :; do
    states=$(docker service ps "$j" --format '{{.Node}}|{{.CurrentState}}|{{.Error}}')
    pending=$(awk -F'|' '{split($2, s, " ")} s[1] != "Complete" && s[1] != "Failed" && s[1] != "Rejected"' <<<"$states")
    [ -n "$states" ] && [ -z "$pending" ] && break
    if [ $SECONDS -ge $deadline ]; then
      echo "::warning::Timeout pour $image : $pending"
      failed=1
      continue 2
    fi
    sleep 3
  done
  while IFS='|' read -r node state error; do
    if [[ $state == Complete* ]]; then
      echo "✓ ${image%@*} sur $node"
    else
      echo "::warning::Échec du pré-téléchargement de ${image%@*} sur $node : $state $error"
      failed=1
    fi
  done <<<"$states"
done

exit $failed
