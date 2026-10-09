#!/bin/sh
# Entrypoint de redis-ha.yml : `redis-ha-entrypoint.sh redis` pour un nœud de
# données, `redis-ha-entrypoint.sh sentinel` pour un sentinel.
#
# Environnement : NODE_NAME (nom DNS du service, aussi annoncé aux pairs),
# DEFAULT_MASTER (master au tout premier démarrage), SENTINELS (liste des
# sentinels), MAXMEMORY (nœuds de données).
#
# Les nœuds ne gardent aucun état (cache pur, pas de volume) : au démarrage ils
# demandent donc aux sentinels qui est le master du moment, plutôt que de se
# fier à une config figée qui ne survivrait pas à une bascule.
set -eu

PORT_SENTINEL=26379

# Master courant selon les sentinels (hors soi-même), vide s'il n'y en a aucun
# de joignable. Les sentinels annoncent des noms d'hôte (announce-hostnames).
current_master() {
  for s in $SENTINELS; do
    [ "$s" = "$NODE_NAME" ] && continue
    m=$(timeout 2 valkey-cli -h "$s" -p "$PORT_SENTINEL" sentinel get-master-addr-by-name mymaster 2>/dev/null | head -n 1) || continue
    [ -n "$m" ] && { echo "$m"; return; }
  done
  return 0
}

MASTER=$(current_master)
MASTER=${MASTER:-$DEFAULT_MASTER}

case "${1:-}" in
  redis)
    # Replica de tout master autre que soi. Un nœud que les sentinels croient
    # encore master (crash avant bascule) redémarre master, mais vide : son
    # replica se resynchronise sur lui. Acceptable pour un cache.
    set -- --replicaof "$MASTER" 6379
    [ "$MASTER" = "$NODE_NAME" ] && set --
    # Cache pur : ni RDB ni AOF. Sync diskless, pas de disque à solliciter.
    # Pas de min-replicas-to-write : on préfère rester dispo en écriture quand
    # le replica tombe.
    exec valkey-server --port 6379 --protected-mode no \
      --save "" --appendonly no --repl-diskless-sync yes \
      --maxmemory "$MAXMEMORY" --maxmemory-policy allkeys-lru \
      --replica-announce-ip "$NODE_NAME" --replica-serve-stale-data yes \
      "$@"
    ;;
  sentinel)
    # Sentinel réécrit son fichier de conf : copie locale, jamais le config
    # Swarm (lecture seule). myid fixe, sinon chaque redémarrage ajoute un
    # sentinel fantôme chez les pairs et fausse le calcul de majorité.
    conf=/tmp/sentinel.conf
    cat > "$conf" <<EOF
port $PORT_SENTINEL
protected-mode no
dir /tmp
sentinel myid $(printf '%s' "$NODE_NAME" | sha1sum | cut -c1-40)
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip $NODE_NAME
sentinel monitor mymaster $MASTER 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 30000
sentinel parallel-syncs mymaster 1
EOF
    exec valkey-sentinel "$conf"
    ;;
  *)
    echo "usage: $0 redis|sentinel" >&2
    exit 64
    ;;
esac
