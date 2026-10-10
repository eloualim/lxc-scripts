#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
bash create-odoo.sh --help >/dev/null
if bash create-odoo.sh 17 >/dev/null 2>&1; then echo 'Invalid version accepted'; exit 1; fi
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_LOG="$TEST_DIR/log"
export PATH="$TEST_DIR:$PATH"
export BRIDGE=lo
cat > "$TEST_DIR/mock" <<'EOF'
#!/usr/bin/env bash
set -eu
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$TEST_LOG"
case "$name $*" in
  'git '*) exit "${MOCK_GIT_EXIT:-0}" ;;
  'pvesh '*) echo 220 ;;
  'pveam available '*) echo 'system ubuntu-24.04-standard_24.04-2_amd64.tar.zst' ;;
  'pct create '*) exit "${MOCK_CREATE_EXIT:-0}" ;;
esac
EOF
chmod +x "$TEST_DIR/mock"
for cmd in pct pveam pvesm pvesh git; do ln -s mock "$TEST_DIR/$cmd"; done
for version in 18 19 20; do
  : > "$TEST_LOG"
  bash create-odoo.sh "$version" >/dev/null
  grep -q -- '--unprivileged 1' "$TEST_LOG"
  grep -q "pct exec 220 -- bash /root/install-odoo.sh $version" "$TEST_LOG"
  if grep -q 'pct destroy' "$TEST_LOG"; then exit 1; fi
done
: > "$TEST_LOG"
if MOCK_GIT_EXIT=2 bash create-odoo.sh 20 >/dev/null 2>&1; then exit 1; fi
if grep -q 'pct create' "$TEST_LOG"; then echo 'Created without branch'; exit 1; fi
: > "$TEST_LOG"
if MOCK_CREATE_EXIT=1 bash create-odoo.sh 19 >/dev/null 2>&1; then exit 1; fi
if grep -Eq 'pct (start|push|exec|destroy)' "$TEST_LOG"; then echo 'Touched existing CT'; exit 1; fi
echo 'Proxmox simulation passed: versions, missing branch, occupied ID.'
