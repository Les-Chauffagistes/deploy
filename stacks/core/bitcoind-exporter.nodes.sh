# Config de l'exporteur bitcoind par nœud, sourcée par le wrapper de
# bitcoind-exporter.yml. $NODE vaut le hostname du nœud Swarm sur lequel
# tourne la tâche ({{.Node.Hostname}}, aussi le label `node` des métriques).
#
# Ajouter un bitcoind : une entrée ci-dessous, puis bumper le nom du config
# `bitcoind_exporter_nodes_vN` dans bitcoind-exporter.yml (les Docker configs
# sont immuables). RPC_HOST doit être joignable depuis le conteneur.
# Un nœud absent de la table fait échouer la tâche plutôt que de scraper
# un mauvais bitcoind.
case "$NODE" in
  debian)
    RPC_HOST=192.168.1.204
    RPC_PORT=8332
    RPC_USER=bitcoinrpc
    ;;
  *)
    echo "bitcoind-exporter: nœud '$NODE' absent de bitcoind-exporter.nodes.sh" >&2
    exit 1
    ;;
esac
