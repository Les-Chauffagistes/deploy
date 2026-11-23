#!/bin/sh
# Pool solo ckpool sur testnet4 qui mine UN bloc pour y faire entrer TARGET_TXID, puis se tait.
# Ce script ne se termine JAMAIS : quoi qu'il arrive (succès, erreur, tx déjà minée) il finit en veille, pour
# que Swarm n'ait aucune raison de relancer le conteneur (un pool relancé re-minerait).
#
# Variables : MINER_ADDRESS (tb1…), TARGET_TXID, MAX_BLOCKS (défaut 1), RPC_HOST, RPC_PORT, RPC_USER.
set -u

CKPOOL_COMMIT=be3e1e0796fbea60b7792a9b62fc2614764e1fc0
MAX_BLOCKS="${MAX_BLOCKS:-1}"
RPC_URL="http://${RPC_HOST}:${RPC_PORT}"

idle() { echo "== $1 =="; echo "Conteneur en veille : retirer ckpool-testnet de stacks/core/ pour le supprimer."; exec sleep infinity; }

# 1. Compilation (image debian publique : pas de dépendance au registre privé).
if ! command -v ckpool >/dev/null 2>&1; then
  echo "Installation des dépendances et compilation de ckpool ${CKPOOL_COMMIT}…"
  export DEBIAN_FRONTEND=noninteractive
  { apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends build-essential autoconf automake libtool pkg-config \
         yasm libzmq3-dev curl jq ca-certificates \
    && mkdir -p /src && cd /src \
    && curl -fsSL "https://bitbucket.org/ckolivas/ckpool/get/${CKPOOL_COMMIT}.tar.gz" | tar xz --strip-components=1 \
    && ./autogen.sh && ./configure && make -j"$(nproc)" && cp src/ckpool /usr/local/bin/ckpool; } \
    >/tmp/build.log 2>&1 || { tail -30 /tmp/build.log; idle "Échec de la compilation"; }
fi

RPC_PASS="$(cat /run/secrets/rpc_password)"
rpc() { # rpc <méthode> [paramètres JSON]
  curl -sf --user "${RPC_USER}:${RPC_PASS}" -H 'content-type: text/plain' \
    --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"ck\",\"method\":\"$1\",\"params\":${2:-[]}}" "$RPC_URL"
}
in_mempool() { rpc getmempoolentry "[\"$TARGET_TXID\"]" 2>/dev/null | jq -e '.result.vsize' >/dev/null 2>&1; }

# 2. Nœud prêt (il peut démarrer en même temps que nous) : 2 minutes d'essais.
i=0
until info="$(rpc getblockchaininfo)" && [ "$(echo "$info" | jq -r .result.initialblockdownload)" = "false" ]; do
  i=$((i + 1)); [ "$i" -ge 24 ] && idle "Nœud RPC injoignable ou en synchronisation"
  sleep 5
done
[ "$(echo "$info" | jq -r .result.chain)" = "testnet4" ] || idle "Le nœud n'est pas sur testnet4"

# 3. La transaction doit être dans le mempool du nœud : on l'y injecte depuis mempool.space si besoin.
if ! in_mempool; then
  hex="$(curl -sf "https://mempool.space/testnet4/api/tx/${TARGET_TXID}/hex")" || hex=""
  [ -n "$hex" ] && rpc sendrawtransaction "[\"$hex\"]" >/dev/null 2>&1
  in_mempool || idle "Transaction absente du mempool et non injectable (déjà minée ? déjà dépensée ?)"
fi

start_height="$(echo "$info" | jq -r .result.blocks)"
echo "Départ à la hauteur $start_height ; arrêt à +$MAX_BLOCKS bloc(s) ou quand ${TARGET_TXID} quitte le mempool."

cat > /tmp/ckpool.conf <<CONF
{
"btcd": [{"url": "${RPC_HOST}:${RPC_PORT}", "auth": "${RPC_USER}", "pass": "${RPC_PASS}", "notify": false}],
"btcaddress": "${MINER_ADDRESS}",
"btcsig": "/testnet4 unstick/",
"blockpoll": 50,
"donation": 0,
"mindiff": 1,
"startdiff": 1,
"serverurl": ["0.0.0.0:3334"],
"logdir": "/tmp/ckpool-logs"
}
CONF

ckpool -B -c /tmp/ckpool.conf -s /tmp/ckpool-sock -L &
pool_pid=$!

# À difficulté 1 un Bitaxe de 3 TH/s trouve un bloc toutes les ~1,4 ms : sans cette boucle le pool
# enchaînerait des centaines de blocs par seconde.
while kill -0 "$pool_pid" 2>/dev/null; do
  height="$(rpc getblockcount | jq -r .result)" || height=""
  if [ -n "$height" ] && [ "$height" -ge $((start_height + MAX_BLOCKS)) ]; then
    kill "$pool_pid" 2>/dev/null; wait "$pool_pid" 2>/dev/null
    idle "Bloc trouvé (hauteur $height) : pool arrêté"
  fi
  if ! in_mempool; then
    kill "$pool_pid" 2>/dev/null; wait "$pool_pid" 2>/dev/null
    idle "Transaction sortie du mempool : pool arrêté"
  fi
  sleep 0.05
done
idle "ckpool s'est arrêté de lui-même"
