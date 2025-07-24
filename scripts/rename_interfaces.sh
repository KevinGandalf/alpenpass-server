#!/bin/sh

ALIASES_FILE="/opt/alpenpass-server/env/interface_aliases"

if [ ! -f "$ALIASES_FILE" ]; then
    echo "❌ Alias-Datei $ALIASES_FILE nicht gefunden!"
    exit 1
fi

echo "==> Interfaces umbenennen gemäß $ALIASES_FILE"

while IFS= read -r line; do
    # Beispiel: adguardvpn (eth1): 192.168.150.2/24 (MAC: 52:54:00:90:e6:b2)
    aliasname=$(echo "$line" | cut -d' ' -f1)
    oldif=$(echo "$line" | sed -n 's/.*(\(.*\)):.*/\1/p')

    if [ -z "$aliasname" ] || [ -z "$oldif" ]; then
        echo "⚠️  Ungültiger Eintrag übersprungen: $line"
        continue
    fi

    if ip link show "$oldif" >/dev/null 2>&1; then
        if ip link show "$aliasname" >/dev/null 2>&1; then
            echo "⚠️  Ziel-Interface $aliasname existiert bereits, überspringe $oldif"
            continue
        fi
        echo "🔄 Umbenennen: $oldif → $aliasname"
        ip link set "$oldif" name "$aliasname"
    else
        echo "⚠️  Interface $oldif nicht gefunden, übersprungen"
    fi
done < "$ALIASES_FILE"

echo "✅ Umbenennung abgeschlossen."
exit 0
