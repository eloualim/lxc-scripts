#!/usr/bin/env bash
# PDF engine for the dedicated Ubuntu 24.04 amd64 Odoo containers.
set -Eeuo pipefail
umask 0022
die() { echo "Erreur : $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Root requis.'
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'Ubuntu 24.04 requis.'
[[ $(dpkg --print-architecture) == amd64 ]] || die 'Architecture amd64 requise.'
id odoo >/dev/null 2>&1 || die 'Installer le compte Odoo avant le moteur PDF.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl fonts-dejavu-core fonts-noto-core poppler-utils
PDF_TMP=$(mktemp -d /tmp/odoo-pdf.XXXXXXXX)
trap 'rm -rf -- "$PDF_TMP"' EXIT
chmod 0755 "$PDF_TMP"
# Same Jammy package used by Odoo's official Ubuntu Noble Docker image.
curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
  https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb \
  -o "$PDF_TMP/wkhtmltox.deb"
echo "4f723b2691ad8638a9df960e0421d346d7315083e3583a334f33362280ddba15  $PDF_TMP/wkhtmltox.deb" | sha256sum --check -
apt-get install -y --no-install-recommends "$PDF_TMP/wkhtmltox.deb"
[[ $(/usr/local/bin/wkhtmltopdf --version) == 'wkhtmltopdf 0.12.6.1 (with patched qt)' ]] || die 'Qt patché non détecté.'
# Verify real rendering, including the Qt-specific header/footer, as Odoo.
install -d -o odoo -g "$(id -gn odoo)" -m 0700 "$PDF_TMP/render"
printf '<html><body><h1>ODOO_PDF_BODY</h1></body></html>\n' > "$PDF_TMP/body.html"
runuser -u odoo -- /usr/local/bin/wkhtmltopdf --quiet \
  --margin-top 20 --margin-bottom 20 --header-center ODOO_PDF_HEADER \
  --footer-center ODOO_PDF_FOOTER "$PDF_TMP/body.html" "$PDF_TMP/render/test.pdf"
pdftotext "$PDF_TMP/render/test.pdf" "$PDF_TMP/render/test.txt"
for marker in ODOO_PDF_BODY ODOO_PDF_HEADER ODOO_PDF_FOOTER; do
  grep -q "$marker" "$PDF_TMP/render/test.txt" || die "Test PDF incomplet : $marker."
done
# Older containers use systemd's default PATH; make binary discovery explicit.
if [[ -f /etc/systemd/system/odoo.service ]]; then
  install -d -m 0755 /etc/systemd/system/odoo.service.d
  printf '[Service]\nEnvironment="PATH=/usr/local/bin:/usr/bin:/bin"\n' > /etc/systemd/system/odoo.service.d/pdf-path.conf
  systemctl daemon-reload
  systemctl try-restart odoo
fi
echo 'Moteur PDF prêt : Qt patché, corps, en-tête et pied de page vérifiés sous le compte Odoo.'
