#!/usr/bin/env bash
# Internal provisioner for a dedicated, fresh Ubuntu 24.04 container.
set -Eeuo pipefail
umask 0022
die() { echo "Erreur : $*" >&2; exit 1; }
VERSION=${1:-}
[[ $VERSION =~ ^(18|19|20)$ ]] || die 'Version attendue : 18, 19 ou 20.'
[[ $EUID == 0 ]] || die 'Root requis.'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f $SCRIPT_DIR/install-pdf.sh ]] || die 'install-pdf.sh doit être présent à côté de cet installateur.'
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'Ubuntu 24.04 requis.'
if [[ -f /etc/odoo-provision-version ]]; then
  [[ $(cat /etc/odoo-provision-version) == "$VERSION" ]] || die 'Une autre version est déjà installée.'
else
  [[ ! -e /opt/odoo && ! -e /etc/odoo.conf ]] || die 'Installation existante non gérée : arrêt.'
  printf '%s\n' "$VERSION" > /etc/odoo-provision-version
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git ca-certificates curl openssl sudo acl openssh-server \
  postgresql postgresql-client python3 python3-venv python3-dev build-essential \
  libldap2-dev libsasl2-dev libpq-dev libxml2-dev libxslt1-dev \
  libjpeg-dev zlib1g-dev libffi-dev libssl-dev liblcms2-dev libopenjp2-7-dev \
  libtiff-dev libwebp-dev libharfbuzz-dev libfribidi-dev libxcb1-dev \
  node-less npm fonts-dejavu-core fonts-noto-core
getent group odoo >/dev/null || groupadd --system odoo
id odoo >/dev/null 2>&1 || useradd --system --gid odoo --home-dir /opt/odoo --shell /bin/bash odoo
id dev >/dev/null 2>&1 || useradd --create-home --shell /bin/bash dev
usermod -aG odoo dev
bash "$SCRIPT_DIR/install-pdf.sh"
install -d -o odoo -g odoo -m 0755 /opt/odoo
install -d -o odoo -g odoo -m 0750 /var/lib/odoo /var/log/odoo
install -d -o dev -g odoo -m 2770 /opt/odoo/custom-addons
# ACL defaults also cover files made by editors with a restrictive umask.
setfacl -R -m u:dev:rwX,u:odoo:rwX,g:odoo:rwX,m::rwX /opt/odoo/custom-addons
find /opt/odoo/custom-addons -type d -exec chmod g+s {} +
find /opt/odoo/custom-addons -type d -exec setfacl -m d:u::rwx,d:u:dev:rwx,d:u:odoo:rwx,d:g::rwx,d:m::rwx,d:o::--- {} +
if [[ -f /root/dev-authorized-key ]]; then
  install -d -o dev -g dev -m 0700 /home/dev/.ssh
  install -o dev -g dev -m 0600 /root/dev-authorized-key /home/dev/.ssh/authorized_keys
fi
install -d -m 0755 /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/00-odoo-dev.conf
systemctl enable --now ssh postgresql
systemctl restart ssh
if [[ ! -d /opt/odoo/src/.git ]]; then
  runuser -u odoo -- git clone --depth 1 --single-branch --branch "$VERSION.0" https://github.com/odoo/odoo.git /opt/odoo/src
fi
[[ $(runuser -u odoo -- git -C /opt/odoo/src branch --show-current) == "$VERSION.0" ]] || die 'Branche Odoo incorrecte.'
systemctl stop odoo 2>/dev/null || true
runuser -u odoo -- python3 -m venv /opt/odoo/venv
runuser -u odoo -- /opt/odoo/venv/bin/pip install --upgrade pip wheel setuptools
runuser -u odoo -- /opt/odoo/venv/bin/pip install -r /opt/odoo/src/requirements.txt
npm install --global rtlcss
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='odoo'" | grep -qx 1; then
  runuser -u postgres -- createuser --createdb --no-createrole --no-superuser odoo
fi
# Local PostgreSQL peer authentication: no database password needed.
if [[ ! -f /etc/odoo.conf ]]; then
  MASTER=$(openssl rand -hex 24)
  install -o root -g odoo -m 0640 /dev/null /etc/odoo.conf
  cat > /etc/odoo.conf <<EOF
[options]
admin_passwd = $MASTER
db_host = False
db_port = False
db_user = odoo
db_password = False
addons_path = /opt/odoo/src/odoo/addons,/opt/odoo/src/addons,/opt/odoo/custom-addons
data_dir = /var/lib/odoo
http_port = 8069
http_interface = 0.0.0.0
workers = 0
proxy_mode = False
list_db = True
log_level = info
EOF
  install -m 0600 /dev/null /root/odoo-credentials.txt
  printf 'Mot de passe maître du gestionnaire de bases Odoo : %s\n' "$MASTER" > /root/odoo-credentials.txt
  unset MASTER
fi
cat > /etc/systemd/system/odoo.service <<'EOF'
[Unit]
Description=Odoo Community development
After=network.target postgresql.service
Requires=postgresql.service
[Service]
Type=simple
User=odoo
Group=odoo
WorkingDirectory=/opt/odoo/src
Environment=HOME=/opt/odoo
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/opt/odoo/venv/bin/python /opt/odoo/src/odoo-bin -c /etc/odoo.conf --dev=reload,xml,qweb
Restart=on-failure
RestartSec=5
UMask=0002
[Install]
WantedBy=multi-user.target
EOF
cat > /usr/local/bin/odoo-scaffold <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && $1 =~ ^[a-z][a-z0-9_]*$ ]] || { echo 'Usage : odoo-scaffold mon_module' >&2; exit 1; }
[[ ! -e /opt/odoo/custom-addons/$1 ]] || { echo 'Ce module existe déjà.' >&2; exit 1; }
umask 0002
exec /opt/odoo/venv/bin/python /opt/odoo/src/odoo-bin scaffold "$1" /opt/odoo/custom-addons
EOF
chmod 0755 /usr/local/bin/odoo-scaffold
cat > /etc/sudoers.d/odoo-dev <<'EOF'
dev ALL=(root) NOPASSWD: /usr/bin/systemctl restart odoo, /usr/bin/systemctl stop odoo, /usr/bin/systemctl start odoo
EOF
chmod 0440 /etc/sudoers.d/odoo-dev
visudo -cf /etc/sudoers.d/odoo-dev
systemctl daemon-reload
systemctl enable --now odoo
ready=0
for ((i=0; i<60; i++)); do
  if curl --fail --silent --output /dev/null http://127.0.0.1:8069/web/database/selector; then ready=1; break; fi
  sleep 2
done
[[ $ready == 1 ]] || { journalctl -u odoo -n 60 --no-pager; die 'Odoo ne répond pas.'; }
echo "Odoo $VERSION opérationnel ; créer la première base depuis le navigateur."
