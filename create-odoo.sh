#!/usr/bin/env bash
# Run on a Proxmox VE node as root.
set -Eeuo pipefail
die() { echo "Erreur : $*" >&2; exit 1; }
if [[ ${1:-} == --help ]]; then
  cat <<'EOF'
Usage: bash create-odoo.sh 18|19|20
Variables optionnelles : CTID, STORAGE=local-lvm, TEMPLATE_STORAGE=local,
BRIDGE=vmbr0, IP=dhcp (ou CIDR), GATEWAY, CORES=2, MEMORY=4096, DISK=24,
SSH_PUBLIC_KEY=/chemin/cle.pub, TEMPLATE=ubuntu-24.04-standard_...tar.zst
EOF
  exit 0
fi
VERSION=${1:-}
[[ $VERSION =~ ^(18|19|20)$ ]] || die 'Choisir 18, 19 ou 20.'
[[ $EUID == 0 ]] || die 'Exécuter sur le nœud Proxmox en root.'
for cmd in pct pveam pvesm pvesh git; do command -v "$cmd" >/dev/null || die "$cmd absent."; done
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f $SCRIPT_DIR/install-odoo.sh ]] || die 'Cloner le dépôt complet.'
[[ -f $SCRIPT_DIR/install-pdf.sh ]] || die 'Installateur PDF absent : mettre à jour le dépôt complet.'
STORAGE=${STORAGE:-local-lvm}; TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}
BRIDGE=${BRIDGE:-vmbr0}; IP=${IP:-dhcp}; GATEWAY=${GATEWAY:-}
CORES=${CORES:-2}; MEMORY=${MEMORY:-4096}; DISK=${DISK:-24}
CTID=${CTID:-$(pvesh get /cluster/nextid)}
[[ $CTID =~ ^[1-9][0-9]{2,8}$ ]] || die 'CTID invalide.'
for value in "$CORES" "$MEMORY" "$DISK"; do [[ $value =~ ^[1-9][0-9]*$ ]] || die 'Ressources invalides.'; done
[[ $BRIDGE =~ ^[a-zA-Z0-9_.-]+$ && -d /sys/class/net/$BRIDGE ]] || die 'Bridge introuvable.'
[[ $STORAGE =~ ^[a-zA-Z0-9_-]+$ && $TEMPLATE_STORAGE =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Stockage invalide.'
[[ $IP == dhcp || $IP =~ ^[0-9.]+/[0-9]{1,2}$ ]] || die 'IP doit être dhcp ou une IPv4/CIDR.'
[[ -z $GATEWAY || $GATEWAY =~ ^[0-9.]+$ ]] || die 'Passerelle invalide.'
[[ $IP != dhcp || -z $GATEWAY ]] || die 'Ne pas définir GATEWAY avec DHCP.'
if [[ -n ${SSH_PUBLIC_KEY:-} ]]; then
  [[ -f $SSH_PUBLIC_KEY ]] || die 'Clé publique introuvable.'
  ssh-keygen -l -f "$SSH_PUBLIC_KEY" >/dev/null || die 'Clé publique invalide.'
fi
git ls-remote --exit-code --heads https://github.com/odoo/odoo.git "$VERSION.0" >/dev/null || die 'Branche officielle indisponible ; aucun conteneur créé.'
pveam update
if [[ -z ${TEMPLATE:-} ]]; then
  TEMPLATE=$(pveam available --section system | awk '$2 ~ /^ubuntu-24.04-standard_/ {print $2}' | sort -V | tail -n 1)
fi
[[ $TEMPLATE =~ ^ubuntu-24\.04-standard_[a-zA-Z0-9_.-]+\.tar\.(zst|gz|xz)$ ]] || die 'Template Ubuntu 24.04 introuvable ou invalide.'
pvesm status --storage "$STORAGE"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[[ -z $GATEWAY ]] || NET+=",gw=$GATEWAY"
echo "Création CT $CTID : Odoo $VERSION, $CORES CPU, ${MEMORY} Mo, ${DISK} Go."
# pct refuses IDs already used anywhere in the cluster. Never destroy on failure.
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "odoo$VERSION-dev" --ostype ubuntu --unprivileged 1 \
  --cores "$CORES" --memory "$MEMORY" --swap 512 \
  --rootfs "$STORAGE:$DISK" --net0 "$NET" --onboot 1
trap 'echo "Échec : CT conservé. Diagnostic : pct enter $CTID ; journalctl -u odoo. Reprise : pct exec $CTID -- bash /root/install-odoo.sh $VERSION" >&2' ERR
pct start "$CTID"
ready=0
for ((i=0; i<60; i++)); do
  if pct exec "$CTID" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ $ready == 1 ]] || die 'Réseau/DNS indisponible après 120 secondes ; CT conservé.'
pct push "$CTID" "$SCRIPT_DIR/install-odoo.sh" /root/install-odoo.sh --perms 700
pct push "$CTID" "$SCRIPT_DIR/install-pdf.sh" /root/install-pdf.sh --perms 700
if [[ -n ${SSH_PUBLIC_KEY:-} ]]; then
  pct push "$CTID" "$SSH_PUBLIC_KEY" /root/dev-authorized-key --perms 600
fi
pct exec "$CTID" -- bash /root/install-odoo.sh "$VERSION"
echo "CT $CTID prêt. Adresses :"
pct exec "$CTID" -- hostname -I
echo "Odoo : http://IP_DU_CT:8069 ; modules : /opt/odoo/custom-addons"
echo "Mot de passe maître : pct exec $CTID -- cat /root/odoo-credentials.txt"
