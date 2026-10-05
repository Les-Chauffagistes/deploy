Oui. Je te propose une migration **sans toucher à `docker-swarm-node02`**, avec les deux WireGuard en parallèle pendant toute l’opération.

On part sur :

```text
ANCIEN WireGuard wg0      NOUVEAU WireGuard wg1

vps-ec31eed6
10.10.0.1                172.16.0.1

iMac-de-Hugo
10.10.0.3                172.16.0.3

backup
10.10.0.4                172.16.0.4

debian
10.10.0.5                172.16.0.5

docker-swarm-node02
NE PAS TOUCHER
```

`10.10.0.0/24` et `172.16.0.0/24` ne se chevauchent pas.

## 1. Vérification avant migration

À faire sur **VPS, backup, iMac et debian** :

```bash
ip route | grep '172\.16\.0\.'
ip addr | grep '172\.16\.0\.'
```

Tu veux idéalement **aucun résultat**.

Vérifie aussi les réseaux Docker :

```bash
sudo docker network ls
```

Et :

```bash
sudo docker network inspect $(sudo docker network ls -q) \
  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
```

Assure-toi que Docker n'utilise pas déjà `172.16.0.0/24`.

> **Pourquoi 172.16.0.0/24 et pas 10.0.0.0/24** : les overlays Swarm occupent tout `10.0.0.0/16`
> (dont `ingress` en `10.0.0.0/24`). Vérifié le 2026-10-05 : aucun réseau ni route en `172.16.x.x`
> sur les 4 machines (les bridges Docker utilisent 172.17 à 172.31).
> Toujours garder `/24` dans `Address` et `AllowedIPs`, jamais `172.16.0.0/16` ni `/12` : ça
> capturerait les bridges Docker locaux.

---

# 2. Sauvegarder l'état actuel des nodes

Sur `vps-ec31eed6` :

```bash
mkdir -p ~/swarm-migration
```

```bash
sudo docker node inspect backup > ~/swarm-migration/backup.json
sudo docker node inspect iMac-de-Hugo > ~/swarm-migration/imac.json
sudo docker node inspect debian > ~/swarm-migration/debian.json
sudo docker node inspect vps-ec31eed6 > ~/swarm-migration/vps.json
```

Regarde surtout les labels :

```bash
sudo docker node inspect backup --format '{{json .Spec.Labels}}'
sudo docker node inspect iMac-de-Hugo --format '{{json .Spec.Labels}}'
sudo docker node inspect debian --format '{{json .Spec.Labels}}'
sudo docker node inspect vps-ec31eed6 --format '{{json .Spec.Labels}}'
```

**Important : les labels sont perdus lorsqu'un node quitte puis rejoint le Swarm.**

Récupère aussi les tokens :

```bash
sudo docker swarm join-token worker
```

```bash
sudo docker swarm join-token manager
```

Garde les deux.

---

# 3. Création des clés du nouveau WireGuard

À faire sur **chacune des 4 machines** :

```bash
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard
```

Puis :

```bash
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/wg1.key'
```

```bash
sudo sh -c 'wg pubkey < /etc/wireguard/wg1.key > /etc/wireguard/wg1.pub'
```

Affiche la clé publique :

```bash
sudo cat /etc/wireguard/wg1.pub
```

Tu dois récupérer :

```text
VPS_PUBLIC_KEY=
BACKUP_PUBLIC_KEY=
IMAC_PUBLIC_KEY=
DEBIAN_PUBLIC_KEY=
```

Ne partage jamais les fichiers `wg1.key`.

---

# 4. Nouveau WireGuard sur le VPS

Sur `vps-ec31eed6` :

```bash
sudo cat /etc/wireguard/wg1.key
```

Copie la clé privée uniquement dans la config locale.

Crée :

```bash
sudo nano /etc/wireguard/wg1.conf
```

Avec :

```ini
[Interface]
Address = 172.16.0.1/24
ListenPort = 51821
PrivateKey = <PRIVATE_KEY_VPS>

[Peer]
PublicKey = <PUBLIC_KEY_BACKUP>
AllowedIPs = 172.16.0.4/32

[Peer]
PublicKey = <PUBLIC_KEY_IMAC>
AllowedIPs = 172.16.0.3/32

[Peer]
PublicKey = <PUBLIC_KEY_DEBIAN>
AllowedIPs = 172.16.0.5/32
```

Comme ton VPS sert de hub entre les machines, active le forwarding :

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

Permanent :

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-wireguard-forward.conf
```

Puis :

```bash
sudo sysctl --system
```

Autorise le forwarding entre peers :

```bash
sudo iptables -I FORWARD 1 -i wg1 -o wg1 -j ACCEPT
```

Et si tu as un firewall INPUT restrictif :

```bash
sudo iptables -I INPUT 1 -p udp --dport 51821 -j ACCEPT
```

Pense également à ouvrir `51821/udp` dans le firewall du fournisseur VPS s'il y en a un.

---

# 5. Configuration `backup`

Sur `backup` :

```bash
sudo nano /etc/wireguard/wg1.conf
```

```ini
[Interface]
Address = 172.16.0.4/24
PrivateKey = <PRIVATE_KEY_BACKUP>

[Peer]
PublicKey = <PUBLIC_KEY_VPS>
Endpoint = <IP_PUBLIQUE_VPS>:51821
AllowedIPs = 172.16.0.0/24
PersistentKeepalive = 25
```

---

# 6. Configuration iMac

Sur `iMac-de-Hugo` :

```bash
sudo nano /etc/wireguard/wg1.conf
```

```ini
[Interface]
Address = 172.16.0.3/24
PrivateKey = <PRIVATE_KEY_IMAC>

[Peer]
PublicKey = <PUBLIC_KEY_VPS>
Endpoint = <IP_PUBLIQUE_VPS>:51821
AllowedIPs = 172.16.0.0/24
PersistentKeepalive = 25
```

---

# 7. Configuration Debian

Sur `debian` :

```bash
sudo nano /etc/wireguard/wg1.conf
```

```ini
[Interface]
Address = 172.16.0.5/24
PrivateKey = <PRIVATE_KEY_DEBIAN>

[Peer]
PublicKey = <PUBLIC_KEY_VPS>
Endpoint = <IP_PUBLIQUE_VPS>:51821
AllowedIPs = 172.16.0.0/24
PersistentKeepalive = 25
```

---

# 8. Démarrer le nouveau WireGuard

D'abord sur le VPS :

```bash
sudo systemctl enable --now wg-quick@wg1
```

Puis backup, iMac et Debian :

```bash
sudo systemctl enable --now wg-quick@wg1
```

Partout :

```bash
sudo wg show wg1
```

```bash
ip addr show wg1
```

---

# 9. Tester le nouveau réseau

Depuis le VPS :

```bash
ping -c 3 172.16.0.4
ping -c 3 172.16.0.3
ping -c 3 172.16.0.5
```

Depuis `backup` :

```bash
ping -c 3 172.16.0.1
ping -c 3 172.16.0.3
ping -c 3 172.16.0.5
```

Depuis iMac :

```bash
ping -c 3 172.16.0.1
ping -c 3 172.16.0.4
```

Depuis Debian :

```bash
ping -c 3 172.16.0.1
ping -c 3 172.16.0.4
```

**Ne passe pas au Swarm tant que `backup ↔ iMac` ne fonctionne pas.**

C'est particulièrement important car ils vont devenir managers ensemble.

---

# 10. Vérifier les ports Swarm sur le nouveau réseau

Les nœuds doivent pouvoir communiquer sur :

```text
2377/tcp
7946/tcp
7946/udp
4789/udp
```

> **Piège rencontré sur `backup`** : il a un pare-feu nftables (`/etc/nftables.conf`, table
> `inet host_fw`, `policy drop`) qui n'accepte que `wg0`. `iptables -S` ne le montre pas (le ping
> passe car ICMP est accepté, mais pas le TCP, ce qui fait échouer la promotion en manager avec
> « could not connect to prospective new cluster member »). Il faut y ajouter `iifname "wg1" accept`
> (fait, sauvegarde dans `/etc/nftables.conf.bak-pre-wg1`) et vérifier avec `nft list tables`.
> Le VPS, l'iMac et debian n'ont pas de table `host_fw`.

Si ton firewall filtre `wg1`, le plus simple sur ce réseau privé est :

```bash
sudo iptables -I INPUT 1 -i wg1 -s 172.16.0.0/24 -j ACCEPT
```

À faire sur les machines concernées si nécessaire.

---

# 11. Migration de `backup`

### Sur le VPS

Regarde les workloads présents :

```bash
sudo docker node ps backup
```

Regarde ses labels :

```bash
sudo docker node inspect backup --format '{{json .Spec.Labels}}'
```

Puis :

```bash
sudo docker node update --availability drain backup
```

Vérifie :

```bash
sudo docker node ls
sudo docker service ls
```

### Sur `backup`

```bash
sudo docker swarm leave
```

### Sur le VPS

Attends quelques secondes :

```bash
sudo docker node ls
```

Puis supprime l'ancienne entrée :

```bash
sudo docker node rm backup
```

---

# 12. Backup rejoint en `172.16.0.4`

Sur `backup` :

```bash
sudo docker swarm join \
  --token <WORKER_TOKEN> \
  --advertise-addr 172.16.0.4 \
  --data-path-addr 172.16.0.4 \
  10.10.0.1:2377
```

Pour l'instant il rejoint via l'ancien manager, mais **sa propre adresse Swarm est déjà la nouvelle**.

Sur le VPS :

```bash
sudo docker node ls
```

Puis :

```bash
sudo docker node inspect backup \
  --format 'Addr={{.Status.Addr}}'
```

Résultat attendu :

```text
Addr=172.16.0.4
```

Remets éventuellement ses labels sauvegardés.

Exemple :

```bash
sudo docker node update --label-add exemple=true backup
```

Puis :

```bash
sudo docker node update --availability active backup
```

---

# 13. Promouvoir backup en manager

Sur VPS :

```bash
sudo docker node promote backup
```

Puis :

```bash
sudo docker node ls
```

Tu dois avoir :

```text
backup          Ready Active Reachable
vps-ec31eed6    Ready Active Leader
```

Vérifie :

```bash
sudo docker node inspect backup \
  --format 'Addr={{.Status.Addr}} Manager={{.ManagerStatus.Addr}}'
```

Résultat attendu :

```text
Addr=172.16.0.4 Manager=172.16.0.4:2377
```

---

# 14. Test critique avant iMac

Depuis le VPS :

```bash
ping -c 3 172.16.0.4
```

Depuis backup :

```bash
ping -c 3 10.10.0.1
```

Puis :

```bash
sudo docker node ls
```

Les deux managers doivent être sains.

Tu es temporairement avec **2 managers**, donc ne traîne pas trop avant d'ajouter le troisième.

---

# 15. Migrer `iMac-de-Hugo`

Sur le VPS ou backup :

```bash
sudo docker node inspect iMac-de-Hugo --format '{{json .Spec.Labels}}'
```

Puis :

```bash
sudo docker node update --availability drain iMac-de-Hugo
```

Vérifie :

```bash
sudo docker service ls
```

### Sur l'iMac

```bash
sudo docker swarm leave
```

### Depuis un manager

```bash
sudo docker node rm iMac-de-Hugo
```

---

# 16. iMac rejoint via le NOUVEAU réseau

Sur l'iMac :

```bash
sudo docker swarm join \
  --token <WORKER_TOKEN> \
  --advertise-addr 172.16.0.3 \
  --data-path-addr 172.16.0.3 \
  172.16.0.4:2377
```

Cette fois, on passe volontairement par `backup`.

Sur le manager :

```bash
sudo docker node inspect iMac-de-Hugo \
  --format 'Addr={{.Status.Addr}}'
```

Attendu :

```text
Addr=172.16.0.3
```

Puis :

```bash
sudo docker node update --availability active iMac-de-Hugo
```

Réapplique ses labels éventuels.

---

# 17. Promouvoir l'iMac

```bash
sudo docker node promote iMac-de-Hugo
```

Puis :

```bash
sudo docker node ls
```

Tu veux maintenant :

```text
vps-ec31eed6    Ready Active Leader
backup          Ready Active Reachable
iMac-de-Hugo    Ready Active Reachable
```

Tu as maintenant **3 managers**, donc quorum 2/3.

C'est beaucoup plus confortable.

---

# 18. Vérifier les 3 managers

Depuis le VPS :

```bash
sudo docker node inspect backup \
  --format '{{.Status.Addr}} {{.ManagerStatus.Addr}}'
```

Tu veux :

```text
172.16.0.4 172.16.0.4:2377
```

Puis :

```bash
sudo docker node inspect iMac-de-Hugo \
  --format '{{.Status.Addr}} {{.ManagerStatus.Addr}}'
```

Tu veux :

```text
172.16.0.3 172.16.0.3:2377
```

Et :

```bash
sudo docker node ls
sudo docker service ls
```

---

# 19. Migrer Debian

Avant :

```bash
sudo docker node inspect debian --format '{{json .Spec.Labels}}'
```

Si tu as bien les labels :

```text
ckpool=true
bitcoind=true
```

note-les.

Puis :

```bash
sudo docker node update --availability drain debian
```

### Sur Debian

```bash
sudo docker swarm leave
```

### Sur le manager

```bash
sudo docker node rm debian
```

### Sur Debian

```bash
sudo docker swarm join \
  --token <WORKER_TOKEN> \
  --advertise-addr 172.16.0.5 \
  --data-path-addr 172.16.0.5 \
  172.16.0.4:2377
```

---

# 20. Réappliquer les labels Debian

Sur manager :

```bash
sudo docker node update \
  --label-add ckpool=true \
  debian
```

Si Bitcoin Core est dessus :

```bash
sudo docker node update \
  --label-add bitcoind=true \
  debian
```

Puis :

```bash
sudo docker node update --availability active debian
```

Vérifie :

```bash
sudo docker node inspect debian \
  --format 'Addr={{.Status.Addr}} Labels={{json .Spec.Labels}}'
```

Attendu :

```text
Addr=172.16.0.5
```

---

# 21. Situation avant migration du VPS

Lance :

```bash
sudo docker node ls
```

Tu dois être à peu près ici :

```text
backup                 Ready Active Reachable
debian                 Ready Active
docker-swarm-node02    Ready Drain
iMac-de-Hugo           Ready Active Reachable
vps-ec31eed6           Ready Active Leader
```

Puis :

```bash
sudo docker node inspect backup \
  --format '{{.Status.Addr}} {{.ManagerStatus.Addr}}'

sudo docker node inspect iMac-de-Hugo \
  --format '{{.Status.Addr}} {{.ManagerStatus.Addr}}'

sudo docker node inspect debian \
  --format '{{.Status.Addr}}'
```

Attendu :

```text
backup : 172.16.0.4
iMac   : 172.16.0.3
debian : 172.16.0.5
```

---

# 22. Tester que backup et iMac peuvent fonctionner sans le control-plane VPS

Très important :

Depuis backup :

```bash
ping -c 5 172.16.0.3
```

Depuis iMac :

```bash
ping -c 5 172.16.0.4
```

Puis depuis backup :

```bash
sudo docker node ls
```

Ça doit fonctionner.

Attention : le **trafic WireGuard entre backup et iMac passe toujours physiquement par le VPS** dans cette architecture hub-and-spoke.

Donc migrer Docker hors de l'ancienne IP du VPS ne supprime pas le VPS comme dépendance réseau WireGuard.

---

# 23. Vérifier les workloads du VPS avant drain

Sur un manager :

```bash
sudo docker node ps vps-ec31eed6
```

Puis :

```bash
sudo docker service ls
```

Tu as notamment des services comme Registry, Traefik, monitoring, etc. Ne continue pas aveuglément si certains reposent sur des volumes locaux uniquement présents sur le VPS.

Puis :

```bash
sudo docker node update --availability drain vps-ec31eed6
```

Regarde la redistribution :

```bash
watch sudo docker service ls
```

Quand tout est stabilisé, quitte avec `Ctrl+C`.

---

# 24. Démoter le VPS

Depuis `backup` ou l'iMac :

```bash
sudo docker node demote vps-ec31eed6
```

Puis :

```bash
sudo docker node ls
```

Un des deux doit devenir :

```text
Leader
```

et l'autre :

```text
Reachable
```

Le VPS ne doit plus avoir de `MANAGER STATUS`.

---

# 25. Faire quitter le VPS

Sur `vps-ec31eed6` :

```bash
sudo docker swarm leave
```

Depuis le nouveau leader :

```bash
sudo docker node rm vps-ec31eed6
```

---

# 26. Récupérer un token manager frais

Sur `backup` ou iMac :

```bash
sudo docker swarm join-token manager
```

Copie le token.

---

# 27. Faire rejoindre directement le VPS comme manager en 172.16.0.1

Sur le VPS :

```bash
sudo docker swarm join \
  --token <MANAGER_TOKEN> \
  --advertise-addr 172.16.0.1 \
  --data-path-addr 172.16.0.1 \
  172.16.0.4:2377
```

Il rejoint directement comme **manager**, pas besoin de promote ensuite.

---

# 28. Vérifier le nouveau VPS manager

Sur un manager :

```bash
sudo docker node ls
```

Tu devrais avoir :

```text
backup                 Ready Active Leader/Reachable
debian                 Ready Active
docker-swarm-node02    Ready Drain
iMac-de-Hugo           Ready Active Reachable/Leader
vps-ec31eed6           Ready Drain Reachable
```

Vérifie son adresse :

```bash
sudo docker node inspect vps-ec31eed6 \
  --format 'Addr={{.Status.Addr}} Manager={{.ManagerStatus.Addr}}'
```

Attendu :

```text
Addr=172.16.0.1 Manager=172.16.0.1:2377
```

---

# 29. Réappliquer les labels éventuels du VPS

Compare avec :

```bash
cat ~/swarm-migration/vps.json
```

Puis au besoin :

```bash
sudo docker node update --label-add XXX=YYY vps-ec31eed6
```

---

# 30. Réactiver le VPS

Quand tout est bon :

```bash
sudo docker node update --availability active vps-ec31eed6
```

Puis :

```bash
sudo docker node ls
sudo docker service ls
```

---

# 31. Vérification globale des IP Swarm

Depuis un manager :

```bash
for NODE in backup debian iMac-de-Hugo vps-ec31eed6; do
    sudo docker node inspect "$NODE" \
      --format '{{.Description.Hostname}} addr={{.Status.Addr}}{{if .ManagerStatus}} manager={{.ManagerStatus.Addr}}{{end}}'
done
```

Tu veux :

```text
backup addr=172.16.0.4 manager=172.16.0.4:2377
debian addr=172.16.0.5
iMac-de-Hugo addr=172.16.0.3 manager=172.16.0.3:2377
vps-ec31eed6 addr=172.16.0.1 manager=172.16.0.1:2377
```

---

# 32. Vérifier les services

```bash
sudo docker service ls
```

Il ne devrait plus y avoir de service qui était `1/1` et passe inexplicablement en `0/1`.

Pour voir tous les conteneurs Swarm :

```bash
sudo docker node ls
```

Puis par node :

```bash
sudo docker node ps backup
sudo docker node ps iMac-de-Hugo
sudo docker node ps debian
sudo docker node ps vps-ec31eed6
```

---

# 33. Ne supprime PAS encore `wg0`

Puisque tu as demandé de ne pas migrer :

```text
docker-swarm-node02
```

je **ne supprimerais pas l'ancien réseau `10.10.0.0/24` du VPS pour l'instant**.

`docker-swarm-node02` est encore membre du Swarm et peut dépendre de ce réseau.

Tu peux donc terminer avec :

```text
VPS
wg0 = 10.10.0.1   ← ancien, conservé pour node02
wg1 = 172.16.0.1    ← nouveau Swarm

backup
wg0 = 10.10.0.4
wg1 = 172.16.0.4

iMac
wg0 = 10.10.0.3
wg1 = 172.16.0.3

debian
wg0 = 10.10.0.5
wg1 = 172.16.0.5

node02
ancien réseau uniquement
```

Une fois `node02` retiré ou migré plus tard, tu pourras supprimer `wg0`.

### Ordre résumé

```text
Créer wg1 172.16.0.0/24
        │
        ▼
backup 172.16.0.4
leave → join → promote
        │
        ▼
iMac 172.16.0.3
leave → join → promote
        │
        ▼
3 managers
VPS + backup + iMac
        │
        ▼
debian 172.16.0.5
leave → join
        │
        ▼
drain VPS
        │
        ▼
demote VPS
        │
        ▼
VPS leave
        │
        ▼
VPS join directement
avec MANAGER_TOKEN
172.16.0.1
        │
        ▼
3 managers sur 172.16.0.x
        │
        ▼
garder wg0 temporairement
pour node02
```

Un point que je changerais à terme : actuellement `wg1` est en **étoile autour du VPS**. Donc même lorsque `backup` et l'iMac sont managers, leur trafic `172.16.0.4 ↔ 172.16.0.3` transite par le VPS. Pour une vraie HA où la perte du VPS ne coupe pas le quorum Swarm, il faudra ensuite faire WireGuard en **full mesh** entre tes trois managers.