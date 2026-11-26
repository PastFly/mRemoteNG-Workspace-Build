#!/bin/bash
# Runs only inside the temporary WSL1 distro created by Test-RdpWslLogon.
set -eu
if [ "${1:-}" = set-passwords ]; then
    # The Windows pipeline terminates the last input record with CRLF.
    LC_ALL=C sed '1s/^\xEF\xBB\xBF//; s/\r$//' | /usr/sbin/chpasswd
    exit
fi
if [ "${1:-}" = verify-bind ]; then
    # Older WSL1 kernels can omit Linux sockets from one or both management APIs.
    bound=$(ss -H -ltn 2>/dev/null | awk '$4 ~ /:34389$/ {print $4}')
    if [ -n "$bound" ]; then
        test "$bound" = '127.0.0.1:34389'
    fi
    grep -qxF 'port=tcp://127.0.0.1:34389' /etc/xrdp/xrdp.ini
    grep -qF 'listening to port 34389 on 127.0.0.1' /var/log/xrdp.log
    exit
fi
if [ "${1:-}" = serve ]; then
    /usr/sbin/xrdp-sesman --nodaemon </dev/null >/tmp/rw-sesman-console.log 2>&1 &
    sesman_pid=$!
    trap 'kill "$sesman_pid" 2>/dev/null || true' EXIT
    /usr/sbin/xrdp --nodaemon </dev/null >/tmp/rw-xrdp-console.log 2>&1
    exit
fi
test -x /usr/sbin/xrdp
test -x /usr/bin/Xtigervnc
# Supply the package's legacy key for xrdp startup, even though it is never
# negotiated on the TLS-only listener.
if [ ! -s /etc/xrdp/rsakeys.ini ]; then /usr/bin/xrdp-keygen xrdp /etc/xrdp/rsakeys.ini; fi
server=rw-xrdp-fixture.test
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj "/CN=$server" \
    -addext "subjectAltName=DNS:$server" -addext "extendedKeyUsage=serverAuth" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -keyout /etc/xrdp/qa-key.pem -out /etc/xrdp/qa-cert.pem 2>/dev/null
chown root:xrdp /etc/xrdp/qa-key.pem
chmod 640 /etc/xrdp/qa-key.pem
chmod 644 /etc/xrdp/qa-cert.pem
# Bind all three layers (RDP, sesman and the nested VNC desktops) to loopback.
sed -i '/^\[Globals\]/,/^\[/{
  s|^port=.*|port=tcp://127.0.0.1:34389|
  s|^security_layer=.*|security_layer=tls|
  s|^certificate=.*|certificate=/etc/xrdp/qa-cert.pem|
  s|^key_file=.*|key_file=/etc/xrdp/qa-key.pem|
  s|^autorun=.*|autorun=Xvnc|
}' /etc/xrdp/xrdp.ini
sed -i 's/^ListenAddress=.*/ListenAddress=127.0.0.1/' /etc/xrdp/sesman.ini
# sesman interprets the first param in this section as the executable.
awk '
    /^\[/ { xvnc = ($0 == "[Xvnc]") }
    xvnc && /^param=/ { next }
    { print }
    /^\[Xvnc\]$/ { print "param=/usr/bin/Xtigervnc\nparam=-localhost=1\nparam=-nolisten\nparam=tcp" }
' /etc/xrdp/sesman.ini >/tmp/rw-sesman.ini
install -m 644 /tmp/rw-sesman.ini /etc/xrdp/sesman.ini
test -x /usr/bin/Xtigervnc
grep -qxF 'port=tcp://127.0.0.1:34389' /etc/xrdp/xrdp.ini
grep -qxF 'security_layer=tls' /etc/xrdp/xrdp.ini
grep -qxF 'autorun=Xvnc' /etc/xrdp/xrdp.ini
grep -qxF 'ListenAddress=127.0.0.1' /etc/xrdp/sesman.ini
for name in rwalpha rwbeta; do
    useradd -m -s /bin/bash "$name"
done
cat >/etc/xrdp/startwm.sh <<'DESKTOP'
#!/bin/sh
set -eu
# Only a successful Linux login followed by access to a live X display reaches
# the marker. xmessage remains a verifiable foreground client of that desktop.
xdpyinfo >/dev/null
printf '%s\n' "$DISPLAY" > "$HOME/.remote-workspace-display"
exec xmessage -center "Remote Workspace QA: $(id -un)"
DESKTOP
chmod 755 /etc/xrdp/startwm.sh
install -d -m 755 /run/xrdp
install -d -m 3777 -o root -g xrdp /run/xrdp/sockdir
install -d -m 1777 /tmp/.X11-unix
