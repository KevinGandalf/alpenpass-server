#!/bin/sh

# Pfade
NET_LO="/etc/init.d/net.lo"
NET_ETH0="/etc/init.d/net.eth0"

# 1. net.lo prüfen oder erstellen
if [ ! -f "$NET_LO" ]; then
    echo "⚙️  Erstelle $NET_LO..."
    cat << 'EOF' > "$NET_LO"
#!/sbin/openrc-run

description="Generic network device loader (used for net.<iface>)"

depend() {
    need localmount
    provide net
    before netmount
}

start() {
    return 0
}

stop() {
    return 0
}
EOF
    chmod +x "$NET_LO"
    echo "✅ $NET_LO wurde erstellt und ausführbar gemacht."
else
    echo "✅ $NET_LO existiert bereits."
fi

# 2. Symlink zu net.eth0 erstellen
if [ ! -L "$NET_ETH0" ]; then
    ln -s "$NET_LO" "$NET_ETH0"
    echo "✅ Symlink $NET_ETH0 → $NET_LO erstellt."
else
    echo "✅ Symlink $NET_ETH0 existiert bereits."
fi

# 3. net.eth0 zum Runlevel hinzufügen
if ! rc-update show | grep -q net.eth0; then
    rc-update add net.eth0 default
    echo "✅ net.eth0 zum Default-Runlevel hinzugefügt."
else
    echo "✅ net.eth0 ist bereits im Default-Runlevel."
fi

# 4. net.eth0 starten
echo "▶️  Starte net.eth0..."
rc-service net.eth0 start

# Abschluss
echo "🏁 net.eth0 ist eingerichtet und aktiv."
