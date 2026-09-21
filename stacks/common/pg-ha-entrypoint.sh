#!/bin/bash
# Entrypoint des nœuds Patroni de pg-ha.yml : charge les secrets, installe la
# config Patroni, lance la boucle de sauvegarde puis l'entrypoint de l'image.
set -euo pipefail

secret() { cat "/run/secrets/$1"; }
export PATRONI_SUPERUSER_USERNAME=postgres
export PATRONI_SUPERUSER_PASSWORD="$(secret superuser_password)"
export PATRONI_REPLICATION_USERNAME=replicator
export PATRONI_REPLICATION_PASSWORD="$(secret replication_password)"
# Protège les endpoints REST qui modifient l'état (switchover, restart...).
export PATRONI_RESTAPI_USERNAME=patroni
export PATRONI_RESTAPI_PASSWORD="$(secret restapi_password)"

# barman-cloud (boto3) vers Garage : région "garage", adressage par chemin.
export AWS_ACCESS_KEY_ID="$(secret s3_key_id)"
export AWS_SECRET_ACCESS_KEY="$(secret s3_secret_key)"
export AWS_DEFAULT_REGION=garage
export AWS_CONFIG_FILE=/tmp/aws-config
printf '[default]\ns3 =\n    addressing_style = path\n' > "$AWS_CONFIG_FILE"

# install et non cp : la copie précédente est en lecture seule.
install -m 0600 /etc/patroni/patroni.yml /home/postgres/postgres.yml

barman() {
  local cmd=$1; shift
  "barman-cloud-$cmd" --endpoint-url "$BARMAN_ENDPOINT" "$@"
}

# Sauvegarde complète quotidienne, lancée par le primaire du moment : toutes
# les 5 min, s'il est primaire, après BACKUP_HOUR_UTC et sans sauvegarde DONE
# du jour dans Garage. Survit donc aux bascules et rattrape une heure manquée.
backup_loop() {
  while sleep 300; do
    curl -sf -o /dev/null http://localhost:8008/primary || continue
    [ "$(date -u +%H)" -ge "$BACKUP_HOUR_UTC" ] || continue
    if ! list=$(barman backup-list --format json "$BARMAN_DEST" "$BARMAN_SERVER" 2>&1); then
      echo "pg-ha-backup: FAILED (liste des sauvegardes) : $list"
      continue
    fi
    today=$(date -u +%Y%m%d)
    python3 -c 'import json, sys
sys.exit(0 if any(b["backup_id"].startswith(sys.argv[1]) and b["status"] == "DONE"
                  for b in json.loads(sys.stdin.read())["backups_list"]) else 1)' "$today" <<<"$list" && continue
    echo "pg-ha-backup: début"
    if barman backup --gzip --immediate-checkpoint -h /var/run/postgresql -U postgres "$BARMAN_DEST" "$BARMAN_SERVER" \
      && barman backup-delete --retention-policy "RECOVERY WINDOW OF $BACKUP_RETENTION_DAYS DAYS" "$BARMAN_DEST" "$BARMAN_SERVER"; then
      echo "pg-ha-backup: OK"
    else
      echo "pg-ha-backup: FAILED"
    fi
  done
}
backup_loop &

exec /patroni_entrypoint.sh
