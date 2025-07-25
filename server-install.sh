#!/bin/sh

set -e

INTERFACES_FILE="/etc/network/interfaces"
ALIASES_FILE="/opt/alpenpass-server/env/interface_aliases"
SYSCTL_FILE="/etc/sysctl.d/99-forwarding.conf"
RT_TABLES_FILE="/etc/iproute2/rt_tables"

# Sicherstellen, dass Konfigdatei existiert
if [ ! -f "$INTERFACES_FILE" ]; then
    echo "auto lo" > "$INTERFACES_FILE"
    echo "iface lo inet loopback" >> "$INTERFACES_FILE"
fi

# Funktion: Liste aller inaktiven physikalischen Interfaces
get_inactive_interfaces() {
    for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
        if echo "$iface" | grep -Eq '^(eth|en|wl)'; then
            if ! ip addr show "$iface" | grep -q 'inet '; then
                echo "$iface"
            fi
        fi
    done
}

# Hauptschleife
while :; do
    inactive_ifaces=$(get_inactive_interfaces)

    if [ -z "$inactive_ifaces" ]; then
        echo "✅ Keine weiteren inaktiven Interfaces gefunden. Beende."
        break
    fi

    iface_count=$(echo "$inactive_ifaces" | wc -l)
    echo ""
    echo "🔍 $iface_count inaktive Netzwerk-Interface(s) gefunden:"
    echo "$inactive_ifaces" | nl -w2 -s'. '

    for iface in $inactive_ifaces; do
        mac=$(cat /sys/class/net/"$iface"/address)
        echo ""
        echo "➤ Konfiguriere Interface: $iface (MAC: $mac)"

        # IP-Adresse eingeben
        while true; do
            printf "🔢 Gib die IP-Adresse mit Netzmaske für %s ein (z.B. 192.168.10.2/24): " "$iface"
            read -r ip_cidr
            if echo "$ip_cidr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
                break
            else
                echo "❌ Ungültiges Format. Bitte erneut eingeben."
            fi
        done

        # Gateway optional eingeben
        printf "🌐 Optional: Gib das Standard-Gateway für %s ein (leer lassen für keines): " "$iface"
        read -r gw

        # Alias eingeben
        printf "🏷️  Möchtest du einen Alias für %s setzen (z.B. nordvpn)? [optional]: " "$iface"
        read -r aliasname

        # IP sofort anwenden
        ip addr add "$ip_cidr" dev "$iface"
        ip link set "$iface" up
        echo "✅ $iface aktiviert mit $ip_cidr"

	# Routing-Tabelle und ip rule nur erstellen, wenn Gateway angegeben wurde
	if [ -n "$gw" ]; then
    	    TABLE_NAME="$iface"

    	   # Prüfen ob Tabelle in /etc/iproute2/rt_tables existiert, sonst hinzufügen
    	   if ! grep -qw "$TABLE_NAME" "$RT_TABLES_FILE"; then
              MAX_ID=$(awk '$1 ~ /^[0-9]+$/ {print $1}' "$RT_TABLES_FILE" | sort -n | tail -n1)
              [ -z "$MAX_ID" ] && MAX_ID=100 || MAX_ID=$((MAX_ID + 1))
              echo "$MAX_ID    $TABLE_NAME" >> "$RT_TABLES_FILE"
              echo "🧭 Routing-Tabelle '$TABLE_NAME' ($MAX_ID) eingetragen."
           fi

    	   # Default-Route nur in der Routing-Tabelle setzen
           ip route add default via "$gw" dev "$iface" table "$TABLE_NAME" 2>/dev/null || true
           echo "🛣️  Default-Route via $gw in Tabelle '$TABLE_NAME' gesetzt."

    	   # ip rule hinzufügen: Traffic mit Quelle der IP geht über eigene Tabelle
    	   SRC_IP=$(echo "$ip_cidr" | cut -d'/' -f1)
    	   ip rule add from "$SRC_IP" table "$TABLE_NAME" priority 1000 2>/dev/null || true
    	   echo "🔀 ip rule für Quelle $SRC_IP zur Tabelle '$TABLE_NAME' hinzugefügt."

    	   # MARK aus IP ableiten (z. B. 192.168.100.x → 100)
    	   MARK=$(echo "$SRC_IP" | cut -d'.' -f3)
    	   if [ -n "$MARK" ]; then
               ip rule add fwmark "$MARK" table "$TABLE_NAME" priority 1001 2>/dev/null || true
               echo "🏷️  ip rule für fwmark $MARK → Tabelle '$TABLE_NAME' hinzugefügt."
    	   fi
	fi

        # In /etc/network/interfaces schreiben
        {
            echo ""
            echo "auto $iface"
            echo "iface $iface inet static"
            echo "    address $(echo "$ip_cidr" | cut -d'/' -f1)"
            echo "    netmask $(ipcalc -m "$ip_cidr" | cut -d'=' -f2)"
            if [ -n "$gw" ]; then
                echo "    gateway $gw"
            fi
        } >> "$INTERFACES_FILE"

        # Alias speichern
        if [ -n "$aliasname" ]; then
            echo "$aliasname ($iface): $ip_cidr (MAC: $mac)" >> "$ALIASES_FILE"
            echo "📝 Alias '$aliasname' gespeichert."
        fi
    done
done

# ==========================================
# 🛡️  sysctl-Konfiguration setzen
# ==========================================
echo ""
echo "==> Erstelle $SYSCTL_FILE mit IP-Forwarding und IPv6-Deaktivierung..."
cat << 'EOF' > "$SYSCTL_FILE"
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
echo "✅ sysctl-Konfiguration gespeichert unter $SYSCTL_FILE"

echo ""
echo "==> Lade sysctl-Konfiguration jetzt sofort..."
sysctl -p "$SYSCTL_FILE"

echo ""
echo "==> Füge sysctl zum Systemstart hinzu (falls noch nicht vorhanden)..."
rc-update add sysctl default 2>/dev/null || true

echo ""
echo "==> Entferne alte SSH-Hostkeys (falls vorhanden)..."
rm -f /etc/ssh/ssh_host_*

echo "==> Generiere neue SSH-Hostkeys..."
ssh-keygen -A

echo "✅ Neue SSH-Hostkeys generiert:"
ls -l /etc/ssh/ssh_host_*

# Optional: SSH-Dienst neustarten, wenn system läuft
if rc-status | grep -q sshd; then
    echo "🔁 Starte sshd neu..."
    rc-service sshd restart
fi

echo ""
echo "✅ Netzwerksetup abgeschlossen!"
echo "    ➤ Interface-Konfiguration: $INTERFACES_FILE"
echo "    ➤ Aliase (optional):       $ALIASES_FILE"
echo "    ➤ sysctl-Konfiguration:    $SYSCTL_FILE"
