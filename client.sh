#!/bin/bash
read -p "Introduce el rango (ej: 25565:25570): " R
S=${R%:*} E=${R#*:} # Separa inicio y fin automáticamente

sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
iptables -t nat -F PREROUTING; iptables -t nat -F POSTROUTING

echo "🔧 Aplicando reglas de $S a $E..."
for port in $(seq $S $E); do
  for proto in tcp udp; do
    iptables -t nat -A PREROUTING -p $proto --dport $port -j DNAT --to-destination 127.0.0.1:$port
    iptables -t nat -A POSTROUTING -p $proto --dport $port -d 127.0.0.1 -j SNAT --to-source 127.0.0.1
  done
done

iptables -t nat -A POSTROUTING -s 172.0.0.0/8 ! -d 172.0.0.0/8 -j MASQUERADE
echo "✅ Listo."
