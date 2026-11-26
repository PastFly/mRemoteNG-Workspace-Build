#!/usr/bin/env bash
# Build the disposable test distro without the application, test accounts or keys.
set -euo pipefail
work=$(mktemp -d)
image="rw-rdp-base-$$"
cid=""
cleanup() {
    [[ -z "$cid" ]] || docker rm -f "$cid" >/dev/null
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
  https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-amd64.tar.gz -o "$work/base.tar.gz"
printf '%s  %s\n' df6fe77cee11bd216ac532f0ee082bdc4da3c0cc1f1d9cb20f3f743196bc4b07 "$work/base.tar.gz" | sha256sum -c -
docker import "$work/base.tar.gz" "$image" >/dev/null
cat >"$work/install" <<'INSTALL'
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
# Use the immutable release pocket. The runner's trusted public CA bundle
# bootstraps HTTPS and Ubuntu's own keyring verifies signed apt metadata.
printf 'deb [arch=amd64] https://archive.ubuntu.com/ubuntu jammy main universe\n' >/etc/apt/sources.list
options=(-o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Acquire::https::Timeout=20 -o Acquire::https::CaInfo=/tmp/fixture-ca.pem)
apt-get "${options[@]}" -qq update
apt-get "${options[@]}" -qq install -y --no-install-recommends xrdp tigervnc-standalone-server x11-utils xauth openssl iproute2 procps
test -x /usr/sbin/xrdp
test -x /usr/sbin/xrdp-sesman
test -x /usr/bin/Xtigervnc
test -x /usr/bin/xmessage
# Packages generate a snakeoil cert and a legacy key. The Windows stage creates
# a new, TLS-only server identity before starting any service.
rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/xrdp/rsakeys.ini
rm -f /var/lib/dbus/machine-id /var/lib/systemd/random-seed /var/lib/urandom/random-seed
truncate -s 0 /etc/machine-id
apt-get clean
rm -rf /var/lib/apt/lists/*
find /var/log -type f -exec truncate -s 0 {} +
INSTALL
cid=$(docker create --mount "type=bind,src=$work/install,dst=/tmp/install,readonly" \
    --mount 'type=bind,src=/etc/ssl/certs/ca-certificates.crt,dst=/tmp/fixture-ca.pem,readonly' \
    "$image" /bin/bash /tmp/install)
docker start --attach "$cid"
test "$(docker inspect -f '{{.State.ExitCode}}' "$cid")" = 0
docker export "$cid" | gzip -1 >test-rdp-rootfs.tar.gz
checksum=$(sha256sum test-rdp-rootfs.tar.gz | cut -d' ' -f1)
printf 'Provisional distro SHA-256 %s\n' "$checksum"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf 'sha256=%s\n' "$checksum" >>"$GITHUB_OUTPUT"; fi
