#!/usr/bin/env bash
# Supprime sur tous les nœuds workload les images de notre registry qui ne
# sont ni utilisées par un conteneur en cours, ni référencées par les stack
# files actuels (donc des versions strictement antérieures au déploiement
# en cours et au précédent pre-pull). Garde toujours le "N-1" en gardant le
# même ensemble que prepull-images.sh.
#
# Usage: prune-images.sh stacks/prod/*.yml stacks/staging/*.yml
set -uo pipefail

REGISTRY="172.16.0.3:5000"
TIMEOUT=600

mapfile -t keep < <(grep -hoE "^\s*image:\s*${REGISTRY//./\\.}/[^[:space:]\"'#]+" "$@" \
  | sed -E 's/^\s*image:\s*//; s/@sha256:.*//' | sort -u)

keep_list=$(printf '%s\n' "${keep[@]}")

run_id="$(date +%s)"
jobs=()
cleanup() { for j in "${jobs[@]}"; do docker service rm "$j" >/dev/null 2>&1; done; }
trap cleanup EXIT

name="prune-${run_id}"
if docker service create --detach --quiet --name "$name" --mode global \
    --constraint "node.labels.workload == true" \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    --restart-condition none docker:27-cli sh -c "
      keep='$keep_list'
      docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep '^${REGISTRY//./\\.}/' |
      while read -r ref id; do
        grep -qxF \"\$ref\" <<<\"\$keep\" && continue   # référencé actuellement -> on garde
        docker rmi \"\$id\" 2>&1 || true                # échoue silencieusement si un conteneur l'utilise encore
      done
      docker image prune -f   # <none>/dangling uniquement, toujours sûr
    " >/dev/null; then
  jobs+=("$name")
else
  echo "::warning::Impossible de créer le job de prune"
fi

failed=0
deadline=$((SECONDS + TIMEOUT))
for j in "${jobs[@]}"; do
  while :; do
    states=$(docker service ps "$j" --format '{{.Node}}|{{.CurrentState}}|{{.Error}}')
    pending=$(awk -F'|' '{split($2, s, " ")} s[1] != "Complete" && s[1] != "Failed" && s[1] != "Rejected"' <<<"$states")
    [ -n "$states" ] && [ -z "$pending" ] && break
    if [ $SECONDS -ge $deadline ]; then
      echo "::warning::Timeout pour le prune : $pending"
      failed=1
      continue 2
    fi
    sleep 3
  done
  while IFS='|' read -r node state error; do
    if [[ $state == Complete* ]]; then
      echo "✓ prune sur $node"
    else
      echo "::warning::Échec du prune sur $node : $state $error"
      failed=1
    fi
  done <<<"$states"
done

exit $failed