#!/usr/bin/env bash
# Supprime du registre privé les vieux tags, sauf ceux référencés dans les
# stack files passés en argument (quel que soit leur âge) et les N plus
# récents par repo. Ne libère pas d'espace : lancer registry-gc.sh après.
#
# Usage: registry-prune-tags.sh stacks/prod/*.yml stacks/staging/*.yml
# Env requis: REGISTRY_USER, REGISTRY_PASSWORD
set -uo pipefail

REGISTRY="172.16.0.3:5000"
KEEP_PROD=10
KEEP_STAGING=5
AUTH="Authorization: Basic $(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_PASSWORD" | base64 -w0)"

mapfile -t keep < <(grep -hoE "^\s*image:\s*${REGISTRY//./\\.}/[^[:space:]\"'#]+" "$@" \
  | sed -E 's/^\s*image:\s*//; s/@sha256:.*//' | sort -u)
keep=("${keep[@]/#${REGISTRY}\//}")

is_kept() {
  local ref=$1
  for k in "${keep[@]}"; do
    [ "$k" = "$ref" ] && return 0
  done
  return 1
}

repos=$(curl -sf -H "$AUTH" "http://$REGISTRY/v2/_catalog?n=1000" | jq -r '.repositories[]?')
[ -z "$repos" ] && { echo "::error::catalogue du registre vide ou inaccessible"; exit 1; }

total_deleted=0
total_failed=0

prune_category() {
  local repo=$1 rows=$2 n=$3 i=0
  while IFS='|' read -r created tag digest; do
    [ -z "$tag" ] && continue
    i=$((i + 1))
    is_kept "$repo:$tag" && continue
    [ "$i" -le "$n" ] && continue
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "$AUTH" \
      "http://$REGISTRY/v2/$repo/manifests/$digest")
    case "$code" in
      202) echo "✓ supprimé $repo:$tag ($created)"; total_deleted=$((total_deleted + 1)) ;;
      404) : ;;
      *) echo "::warning::échec suppression $repo:$tag -> HTTP $code"; total_failed=$((total_failed + 1)) ;;
    esac
  done <<<"$rows"
}

for repo in $repos; do
  tags=$(curl -sf -H "$AUTH" "http://$REGISTRY/v2/$repo/tags/list" | jq -r '.tags[]?')
  [ -z "$tags" ] && continue

  rows=""
  for tag in $tags; do
    headers=$(curl -sf -D - -o /tmp/manifest.$$ -H "$AUTH" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      "http://$REGISTRY/v2/$repo/manifests/$tag") || continue
    digest=$(printf '%s' "$headers" | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}')
    cfgdigest=$(jq -r '.config.digest // empty' /tmp/manifest.$$)
    rm -f /tmp/manifest.$$
    [ -z "$cfgdigest" ] && continue
    created=$(curl -sf -H "$AUTH" "http://$REGISTRY/v2/$repo/blobs/$cfgdigest" | jq -r '.created // empty')
    [ -z "$created" ] && continue
    rows="$rows$created|$tag|$digest
"
  done

  prod_rows=$(printf '%s' "$rows" | grep -E '^\S+\|[0-9]+\.[0-9]+\.[0-9]+\|' | sort -r)
  staging_rows=$(printf '%s' "$rows" | grep -E '^\S+\|sha-[0-9a-f]+\|' | sort -r)

  [ -n "$prod_rows" ] && prune_category "$repo" "$prod_rows" "$KEEP_PROD"
  [ -n "$staging_rows" ] && prune_category "$repo" "$staging_rows" "$KEEP_STAGING"
done

echo "Terminé : $total_deleted supprimés, $total_failed échecs"
[ "$total_failed" -gt 0 ] && exit 1
exit 0
