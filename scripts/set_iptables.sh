#!/bin/bash

RULES_FILE="/etc/iptables/rules.v4"
RT_TABLES_FILE="/etc/iproute2/rt_tables"

# Clean existing iptables rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Set default policies
iptables -P INPUT DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Interfaces erkennen (alle mit IP außer lo)
VPN_INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)

# NAT für alle VPN-Interfaces
for iface in $VPN_INTERFACES; do
    iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
done

# Erlaube localhost
iptables -A INPUT -i lo -j ACCEPT

# Eingehend erlauben: SSH, Ping, HTTP, HTTPS
iptables -A INPUT -p tcp --dport 22 -j ACCEPT   # SSH
iptables -A INPUT -p tcp --dport 80 -j ACCEPT   # HTTP
iptables -A INPUT -p tcp --dport 443 -j ACCEPT  # HTTPS
iptables -A INPUT -p icmp --icmp-type 8 -j ACCEPT  # Ping

# Verbindungstracking
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -s 192.168.0.0/16 -j ACCEPT

# Alte ip rules löschen (Prioritäten 1000 und 1001), um Doppelungen zu vermeiden
for mark in $(awk '!/^#|^$/{print $2}' "$RT_TABLES_FILE" | grep -E '^vpn' || true); do
    ip rule del fwmark "$mark" table "$mark" priority 1001 2>/dev/null || true
    ip rule del table "$mark" priority 1000 2>/dev/null || true
done

# VPN-Interfaces filtern und nur die mit IP und Gateway benutzen
ACTIVE_VPNS=""
declare -A TABLES

i=0
for iface in $VPN_INTERFACES; do
    # IP des Interfaces holen (IPv4)
    ip_cidr=$(ip -o -4 addr show dev "$iface" | awk '{print $4}' | head -n1)

    # Gateway suchen: Default route mit dev iface, sonst erste default route global
    gw=$(ip route show default | grep "dev $iface" | awk '{print $3}' | head -n1)
    if [ -z "$gw" ]; then
        gw=$(ip route show default | awk '{print $3}' | head -n1)
    fi

    if [ -n "$gw" ] && [ -n "$ip_cidr" ]; then
        i=$((i + 1))
        TABLE_NAME="vpn$i"

        # Prüfen ob Tabelle in /etc/iproute2/rt_tables existiert, sonst hinzufügen
        if ! grep -qw "$TABLE_NAME" "$RT_TABLES_FILE"; then
            MAX_ID=$(awk '$1 ~ /^[0-9]+$/ {print $1}' "$RT_TABLES_FILE" | sort -n | tail -n1)
            [ -z "$MAX_ID" ] && MAX_ID=100 || MAX_ID=$((MAX_ID + 1))
            echo "$MAX_ID    $TABLE_NAME" >> "$RT_TABLES_FILE"
            echo "🧭 Routing-Tabelle '$TABLE_NAME' ($MAX_ID) eingetragen."
        fi

        # Default-Route in Routing-Tabelle setzen
        ip route add default via "$gw" dev "$iface" table "$TABLE_NAME" 2>/dev/null || true
        echo "🛣️  Default-Route via $gw in Tabelle '$TABLE_NAME' gesetzt."

        # ip rule: Quelle IP → Tabelle
        SRC_IP=$(echo "$ip_cidr" | cut -d'/' -f1)
        ip rule add from "$SRC_IP" table "$TABLE_NAME" priority 1000 2>/dev/null || true
        echo "🔀 ip rule für Quelle $SRC_IP zur Tabelle '$TABLE_NAME' hinzugefügt."

        # MARK aus drittem Oktett ableiten (z.B. 192.168.10.x → 10)
        MARK=$(echo "$SRC_IP" | cut -d'.' -f3)
        if [ -n "$MARK" ]; then
            ip rule add fwmark "$MARK" table "$TABLE_NAME" priority 1001 2>/dev/null || true
            echo "🏷️  ip rule für fwmark $MARK → Tabelle '$TABLE_NAME' hinzugefügt."
        fi

        # Interface merken
        ACTIVE_VPNS="$ACTIVE_VPNS $TABLE_NAME"
        TABLES[$TABLE_NAME]="$MARK"
    else
        echo "⚠️ Interface $iface hat keine Gateway oder IP, übersprungen."
    fi
done

ACTIVE_VPNS=$(echo $ACTIVE_VPNS | xargs)  # Leerzeichen trimmen

# Anzahl aktive VPNs und Wahrscheinlichkeitswert pro Interface
VPN_COUNT=$(echo $ACTIVE_VPNS | wc -w)
if [ "$VPN_COUNT" -eq 0 ]; then
    echo "❌ Keine aktiven VPN-Interfaces mit Gateway/IP gefunden. Abbruch."
    exit 1
fi
PROB=$(awk "BEGIN {printf \"%.4f\", 1/$VPN_COUNT}")

echo "ℹ️ Anzahl VPN-Interfaces: $VPN_COUNT, Wahrscheinlichkeit pro Interface: $PROB"

# Markierungen im mangle PREROUTING setzen mit Statistik-Modul (Lastverteilung)
iptables -t mangle -F PREROUTING
for ((idx=1; idx<=VPN_COUNT; idx++)); do
    TABLE="vpn$idx"
    MARK=$(echo "${TABLES[$TABLE]}" | tr -d ' ')
    if [ "$idx" -lt "$VPN_COUNT" ]; then
        iptables -t mangle -A PREROUTING -s 192.168.10.0/24 -m statistic --mode random --probability "$PROB" -j MARK --set-mark "$MARK"
        echo "🏷️ Mark $MARK mit Wahrscheinlichkeit $PROB gesetzt."
    else
        # Rest: alles andere bekommt Mark des letzten Interfaces (kein Wahrscheinlichkeit nötig)
        iptables -t mangle -A PREROUTING -s 192.168.10.0/24 -j MARK --set-mark "$MARK"
        echo "🏷️ Restlicher Traffic bekommt Mark $MARK (Standard)."
    fi
done

# Regeln speichern
#/etc/init.d/iptables save
iptables-save > $RULES_FILE
echo "✅ iptables-Regeln gespeichert."

# iptables-Service aktivieren und starten
if rc-service iptables status >/dev/null 2>&1; then
    rc-service iptables restart
else
    rc-update add iptables default
    rc-service iptables start
fi

echo "✅ iptables-Service gestartet und zum Default-Runlevel hinzugefügt."
